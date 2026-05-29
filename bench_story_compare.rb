# frozen_string_literal: true
require 'json'
require 'pg'
require 'mini_sql'
require 'active_record'
require 'logger'

DURATION = Integer(ENV.fetch('BENCH_SECONDS', '60'))
DB = ENV.fetch('PGDATABASE', 'discourse_sql_ft')
USER_NAME = ENV.fetch('PGUSER', 'agent')
DB_HOST = ENV.fetch('PGHOST', nil)
MODE = ENV.fetch('BENCH_MODE') # mini_sql or active_record

SCENARIO = "Discourse-ish browsing session: latest page, topic page, user card, category dashboard, ephemeral autosave write/readback"

RNG_SEED = 20260529

def measure(metrics, name)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  rows = yield
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  m = metrics[name]
  m[:calls] += 1
  m[:seconds] += elapsed
  m[:rows] += rows.to_i
end

def finish_report(metrics, started, sessions)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  ops = metrics.values.sum { |m| m[:calls] }
  rows = metrics.values.sum { |m| m[:rows] }
  summary = metrics.transform_values do |m|
    {
      calls: m[:calls],
      rows: m[:rows],
      seconds: m[:seconds],
      avg_ms: m[:calls] > 0 ? (m[:seconds] * 1000.0 / m[:calls]) : 0.0,
      calls_per_second: m[:calls] / elapsed
    }
  end

  puts JSON.pretty_generate({
    story: SCENARIO,
    mode: MODE,
    ruby: RUBY_VERSION,
    ruby_description: RUBY_DESCRIPTION,
    mini_sql: Gem.loaded_specs['mini_sql']&.version&.to_s,
    active_record: Gem.loaded_specs['activerecord']&.version&.to_s,
    pg: Gem.loaded_specs['pg']&.version&.to_s,
    db: DB,
    duration_seconds: elapsed,
    sessions: sessions,
    sessions_per_second: sessions / elapsed,
    operations: ops,
    operations_per_second: ops / elapsed,
    rows_materialized: rows,
    scenarios: summary
  })
end

if MODE == 'mini_sql'
  pg = PG.connect(dbname: DB, user: USER_NAME, host: DB_HOST)
  conn = MiniSql::Connection.get(pg)
  conn.exec <<~SQL
    create temp table if not exists bench_events(
      id serial primary key,
      user_id int,
      topic_id int,
      payload text,
      created_at timestamp default now()
    )
  SQL

  topic_ids = conn.query_single("select array_agg(id order by bumped_at desc) from (select id, bumped_at from topics where deleted_at is null and archetype <> 'private_message' order by bumped_at desc limit 250) t").first
  user_ids = conn.query_single("select array_agg(id order by last_seen_at desc nulls last) from (select id, last_seen_at from users where active = true order by last_seen_at desc nulls last limit 200) u").first
  category_ids = conn.query_single("select array_agg(id order by id) from categories").first

  rng = Random.new(RNG_SEED)
  200.times do
    conn.query("select id, title from topics where id = :id", id: topic_ids.sample(random: rng))
    conn.query("select id, username from users where id = :id", id: user_ids.sample(random: rng))
  end

  metrics = Hash.new { |h, k| h[k] = { calls: 0, seconds: 0.0, rows: 0 } }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = started + DURATION
  sessions = 0
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    topic_id = topic_ids.sample(random: rng)
    user_id = user_ids.sample(random: rng)
    category_id = category_ids.sample(random: rng)

    measure(metrics, :latest_page) do
      conn.query(<<~SQL, category_id: category_id).length
        select t.id, t.title, t.views, t.posts_count, t.bumped_at,
               c.name as category_name,
               u.username as author,
               lu.username as last_poster
        from topics t
        join users u on u.id = t.user_id
        join users lu on lu.id = t.last_post_user_id
        left join categories c on c.id = t.category_id
        where t.deleted_at is null
          and t.visible = true
          and t.archetype <> 'private_message'
          and (:category_id::int is null or t.category_id = :category_id)
        order by t.bumped_at desc
        limit 30
      SQL
    end

    measure(metrics, :topic_header) do
      conn.query(<<~SQL, id: topic_id).length
        select t.id, t.title, t.views, t.like_count, t.posts_count,
               c.name as category_name,
               u.username as author
        from topics t
        join users u on u.id = t.user_id
        left join categories c on c.id = t.category_id
        where t.id = :id
      SQL
    end

    measure(metrics, :post_stream) do
      conn.query(<<~SQL, topic_id: topic_id).length
        select p.id, p.post_number, p.user_id, u.username,
               p.created_at, p.like_count, p.cooked
        from posts p
        join users u on u.id = p.user_id
        where p.topic_id = :topic_id
          and p.deleted_at is null
        order by p.post_number
        limit 20
      SQL
    end

    measure(metrics, :user_card) do
      conn.query(<<~SQL, user_id: user_id).length
        select u.id, u.username, u.name, u.trust_level,
               count(p.id) as recent_posts,
               coalesce(sum(p.like_count), 0) as recent_likes,
               max(p.created_at) as last_post_at
        from users u
        left join posts p on p.user_id = u.id and p.deleted_at is null
        where u.id = :user_id
        group by u.id, u.username, u.name, u.trust_level
      SQL
    end

    measure(metrics, :category_counts) do
      conn.query(<<~SQL).length
        select c.id, c.name, count(t.id) as topic_count, coalesce(sum(t.posts_count), 0) as post_count
        from categories c
        left join topics t on t.category_id = c.id and t.deleted_at is null and t.visible = true
        group by c.id, c.name
        order by topic_count desc, c.id
        limit 20
      SQL
    end

    measure(metrics, :temp_write_event) do
      conn.exec("insert into bench_events(user_id, topic_id, payload) values(:user_id, :topic_id, :payload)", user_id: user_id, topic_id: topic_id, payload: "autosave:#{sessions}")
      1
    end

    measure(metrics, :temp_readback) do
      conn.query_single("select count(*) from bench_events where user_id = :user_id", user_id: user_id)
      1
    end

    sessions += 1
  end
  finish_report(metrics, started, sessions)

elsif MODE == 'active_record'
  ActiveRecord::Base.establish_connection(adapter: 'postgresql', database: DB, username: USER_NAME, host: DB_HOST)
  ActiveRecord::Base.logger = nil

  class User < ActiveRecord::Base
    self.table_name = 'users'
    has_many :posts, foreign_key: :user_id
  end

  class Category < ActiveRecord::Base
    self.table_name = 'categories'
    has_many :topics, foreign_key: :category_id
  end

  class Topic < ActiveRecord::Base
    self.table_name = 'topics'
    belongs_to :user, foreign_key: :user_id, optional: true
    belongs_to :last_poster, class_name: 'User', foreign_key: :last_post_user_id, optional: true
    belongs_to :category, optional: true
    has_many :posts, foreign_key: :topic_id
  end

  class Post < ActiveRecord::Base
    self.table_name = 'posts'
    belongs_to :user, optional: true
    belongs_to :topic, optional: true
  end

  ActiveRecord::Base.connection.execute <<~SQL
    create temp table if not exists bench_events(
      id serial primary key,
      user_id int,
      topic_id int,
      payload text,
      created_at timestamp default now()
    )
  SQL

  class BenchEvent < ActiveRecord::Base
    self.table_name = 'bench_events'
  end
  BenchEvent.reset_column_information

  topic_ids = Topic.where(deleted_at: nil).where.not(archetype: 'private_message').order(bumped_at: :desc).limit(250).pluck(:id)
  user_ids = User.where(active: true).order(Arel.sql('last_seen_at desc nulls last')).limit(200).pluck(:id)
  category_ids = Category.order(:id).pluck(:id)

  rng = Random.new(RNG_SEED)
  200.times do
    Topic.select(:id, :title).where(id: topic_ids.sample(random: rng)).to_a
    User.select(:id, :username).where(id: user_ids.sample(random: rng)).to_a
  end

  metrics = Hash.new { |h, k| h[k] = { calls: 0, seconds: 0.0, rows: 0 } }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = started + DURATION
  sessions = 0
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    topic_id = topic_ids.sample(random: rng)
    user_id = user_ids.sample(random: rng)
    category_id = category_ids.sample(random: rng)

    measure(metrics, :latest_page) do
      Topic
        .joins(:user)
        .joins('join users last_posters on last_posters.id = topics.last_post_user_id')
        .left_joins(:category)
        .where(deleted_at: nil, visible: true)
        .where.not(archetype: 'private_message')
        .where(category_id: category_id)
        .select('topics.id, topics.title, topics.views, topics.posts_count, topics.bumped_at, categories.name as category_name, users.username as author, last_posters.username as last_poster')
        .order(bumped_at: :desc)
        .limit(30)
        .to_a
        .length
    end

    measure(metrics, :topic_header) do
      Topic
        .joins(:user)
        .left_joins(:category)
        .where(id: topic_id)
        .select('topics.id, topics.title, topics.views, topics.like_count, topics.posts_count, categories.name as category_name, users.username as author')
        .to_a
        .length
    end

    measure(metrics, :post_stream) do
      Post
        .joins(:user)
        .where(topic_id: topic_id, deleted_at: nil)
        .select('posts.id, posts.post_number, posts.user_id, users.username, posts.created_at, posts.like_count, posts.cooked')
        .order(:post_number)
        .limit(20)
        .to_a
        .length
    end

    measure(metrics, :user_card) do
      User
        .left_joins(:posts)
        .where(id: user_id)
        .where('posts.deleted_at is null or posts.id is null')
        .select('users.id, users.username, users.name, users.trust_level, count(posts.id) as recent_posts, coalesce(sum(posts.like_count), 0) as recent_likes, max(posts.created_at) as last_post_at')
        .group('users.id, users.username, users.name, users.trust_level')
        .to_a
        .length
    end

    measure(metrics, :category_counts) do
      Category
        .joins('left join topics on topics.category_id = categories.id and topics.deleted_at is null and topics.visible = true')
        .select('categories.id, categories.name, count(topics.id) as topic_count, coalesce(sum(topics.posts_count), 0) as post_count')
        .group('categories.id, categories.name')
        .order(Arel.sql('topic_count desc, categories.id'))
        .limit(20)
        .to_a
        .length
    end

    measure(metrics, :temp_write_event) do
      BenchEvent.create!(user_id: user_id, topic_id: topic_id, payload: "autosave:#{sessions}")
      1
    end

    measure(metrics, :temp_readback) do
      BenchEvent.where(user_id: user_id).count
      1
    end

    sessions += 1
  end
  finish_report(metrics, started, sessions)
else
  raise "unknown BENCH_MODE=#{MODE.inspect}; use mini_sql or active_record"
end

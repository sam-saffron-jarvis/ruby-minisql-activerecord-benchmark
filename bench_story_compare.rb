# frozen_string_literal: true
require 'json'
require 'pg'
require 'mini_sql'
require 'active_record'
require 'sequel'
require 'logger'

DURATION = Integer(ENV.fetch('BENCH_SECONDS', '60'))
DB = ENV.fetch('PGDATABASE', 'discourse_sql_ft')
USER_NAME = ENV.fetch('PGUSER', 'agent')
DB_HOST = ENV.fetch('PGHOST', nil)
MODE = ENV.fetch('BENCH_MODE') # mini_sql, active_record, or sequel

SCENARIO = "Discourse-ish browsing session: latest page, topic page, user card, category dashboard, ephemeral autosave write/readback"

RNG_SEED = 20260529

def measure(metrics, name)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  rows, bytes = result.is_a?(Array) ? result : [result.to_i, 0]
  m = metrics[name]
  m[:calls] += 1
  m[:seconds] += elapsed
  m[:rows] += rows.to_i
  m[:bytes] += bytes.to_i
end

def materialize_rows(rows, *fields)
  out = String.new(capacity: 16 * 1024)
  count = 0

  rows.each do |row|
    fields.each do |field|
      value = row.is_a?(Hash) ? row[field] : row.public_send(field)
      out << value.to_s
      out << "\t"
    end
    out << "\n"
    count += 1
  end

  [count, out.bytesize]
end

def materialize_scalar(value)
  text = value.to_s
  [1, text.bytesize]
end

def finish_report(metrics, started, sessions)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  ops = metrics.values.sum { |m| m[:calls] }
  rows = metrics.values.sum { |m| m[:rows] }
  bytes = metrics.values.sum { |m| m[:bytes] }
  summary = metrics.transform_values do |m|
    {
      calls: m[:calls],
      rows: m[:rows],
      bytes: m[:bytes],
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
    yjit: defined?(RubyVM::YJIT) ? RubyVM::YJIT.enabled? : false,
    mini_sql: Gem.loaded_specs['mini_sql']&.version&.to_s,
    active_record: Gem.loaded_specs['activerecord']&.version&.to_s,
    sequel: Gem.loaded_specs['sequel']&.version&.to_s,
    pg: Gem.loaded_specs['pg']&.version&.to_s,
    db: DB,
    duration_seconds: elapsed,
    sessions: sessions,
    sessions_per_second: sessions / elapsed,
    operations: ops,
    operations_per_second: ops / elapsed,
    rows_materialized: rows,
    bytes_materialized: bytes,
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

  metrics = Hash.new { |h, k| h[k] = { calls: 0, seconds: 0.0, rows: 0, bytes: 0 } }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = started + DURATION
  sessions = 0
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    topic_id = topic_ids.sample(random: rng)
    user_id = user_ids.sample(random: rng)
    category_id = category_ids.sample(random: rng)

    measure(metrics, :latest_page) do
      rows = conn.query(<<~SQL, category_id: category_id)
        select t.id, t.title, t.views, t.posts_count, t.bumped_at,
               c.name as category_name,
               u.username as author,
               lu.username as last_poster_username
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
      materialize_rows(rows, :id, :title, :views, :posts_count, :bumped_at, :category_name, :author, :last_poster_username)
    end

    measure(metrics, :topic_header) do
      rows = conn.query(<<~SQL, id: topic_id)
        select t.id, t.title, t.views, t.like_count, t.posts_count,
               c.name as category_name,
               u.username as author
        from topics t
        join users u on u.id = t.user_id
        left join categories c on c.id = t.category_id
        where t.id = :id
      SQL
      materialize_rows(rows, :id, :title, :views, :like_count, :posts_count, :category_name, :author)
    end

    measure(metrics, :post_stream) do
      rows = conn.query(<<~SQL, topic_id: topic_id)
        select p.id, p.post_number, p.user_id, u.username,
               p.created_at, p.like_count, p.cooked
        from posts p
        join users u on u.id = p.user_id
        where p.topic_id = :topic_id
          and p.deleted_at is null
        order by p.post_number
        limit 20
      SQL
      materialize_rows(rows, :id, :post_number, :user_id, :username, :created_at, :like_count, :cooked)
    end

    measure(metrics, :user_card) do
      rows = conn.query(<<~SQL, user_id: user_id)
        select u.id, u.username, u.name, u.trust_level,
               count(p.id) as recent_posts,
               coalesce(sum(p.like_count), 0) as recent_likes,
               max(p.created_at) as last_post_at
        from users u
        left join posts p on p.user_id = u.id and p.deleted_at is null
        where u.id = :user_id
        group by u.id, u.username, u.name, u.trust_level
      SQL
      materialize_rows(rows, :id, :username, :name, :trust_level, :recent_posts, :recent_likes, :last_post_at)
    end

    measure(metrics, :category_counts) do
      rows = conn.query(<<~SQL)
        select c.id, c.name, count(t.id) as topic_count, coalesce(sum(t.posts_count), 0) as post_count
        from categories c
        left join topics t on t.category_id = c.id and t.deleted_at is null and t.visible = true
        group by c.id, c.name
        order by topic_count desc, c.id
        limit 20
      SQL
      materialize_rows(rows, :id, :name, :topic_count, :post_count)
    end

    measure(metrics, :temp_write_event) do
      payload = "autosave:#{sessions}"
      conn.exec("insert into bench_events(user_id, topic_id, payload) values(:user_id, :topic_id, :payload)", user_id: user_id, topic_id: topic_id, payload: payload)
      [1, payload.bytesize]
    end

    measure(metrics, :temp_readback) do
      materialize_scalar(conn.query_single("select count(*) from bench_events where user_id = :user_id", user_id: user_id).first)
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

  metrics = Hash.new { |h, k| h[k] = { calls: 0, seconds: 0.0, rows: 0, bytes: 0 } }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = started + DURATION
  sessions = 0
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    topic_id = topic_ids.sample(random: rng)
    user_id = user_ids.sample(random: rng)
    category_id = category_ids.sample(random: rng)

    measure(metrics, :latest_page) do
      rows = Topic
        .joins(:user)
        .joins('join users last_posters on last_posters.id = topics.last_post_user_id')
        .left_joins(:category)
        .where(deleted_at: nil, visible: true)
        .where.not(archetype: 'private_message')
        .where(category_id: category_id)
        .select('topics.id, topics.title, topics.views, topics.posts_count, topics.bumped_at, categories.name as category_name, users.username as author, last_posters.username as last_poster_username')
        .order(bumped_at: :desc)
        .limit(30)
        .to_a
      materialize_rows(rows, :id, :title, :views, :posts_count, :bumped_at, :category_name, :author, :last_poster_username)
    end

    measure(metrics, :topic_header) do
      rows = Topic
        .joins(:user)
        .left_joins(:category)
        .where(id: topic_id)
        .select('topics.id, topics.title, topics.views, topics.like_count, topics.posts_count, categories.name as category_name, users.username as author')
        .to_a
      materialize_rows(rows, :id, :title, :views, :like_count, :posts_count, :category_name, :author)
    end

    measure(metrics, :post_stream) do
      rows = Post
        .joins(:user)
        .where(topic_id: topic_id, deleted_at: nil)
        .select('posts.id, posts.post_number, posts.user_id, users.username, posts.created_at, posts.like_count, posts.cooked')
        .order(:post_number)
        .limit(20)
        .to_a
      materialize_rows(rows, :id, :post_number, :user_id, :username, :created_at, :like_count, :cooked)
    end

    measure(metrics, :user_card) do
      rows = User
        .left_joins(:posts)
        .where(id: user_id)
        .where('posts.deleted_at is null or posts.id is null')
        .select('users.id, users.username, users.name, users.trust_level, count(posts.id) as recent_posts, coalesce(sum(posts.like_count), 0) as recent_likes, max(posts.created_at) as last_post_at')
        .group('users.id, users.username, users.name, users.trust_level')
        .to_a
      materialize_rows(rows, :id, :username, :name, :trust_level, :recent_posts, :recent_likes, :last_post_at)
    end

    measure(metrics, :category_counts) do
      rows = Category
        .joins('left join topics on topics.category_id = categories.id and topics.deleted_at is null and topics.visible = true')
        .select('categories.id, categories.name, count(topics.id) as topic_count, coalesce(sum(topics.posts_count), 0) as post_count')
        .group('categories.id, categories.name')
        .order(Arel.sql('topic_count desc, categories.id'))
        .limit(20)
        .to_a
      materialize_rows(rows, :id, :name, :topic_count, :post_count)
    end

    measure(metrics, :temp_write_event) do
      payload = "autosave:#{sessions}"
      BenchEvent.create!(user_id: user_id, topic_id: topic_id, payload: payload)
      [1, payload.bytesize]
    end

    measure(metrics, :temp_readback) do
      materialize_scalar(BenchEvent.where(user_id: user_id).count)
    end

    sessions += 1
  end
  finish_report(metrics, started, sessions)

elsif MODE == 'sequel'
  db_opts = { adapter: 'postgres', database: DB, user: USER_NAME }
  db_opts[:host] = DB_HOST if DB_HOST
  db = Sequel.connect(db_opts)

  db.run <<~SQL
    create temp table if not exists bench_events(
      id serial primary key,
      user_id int,
      topic_id int,
      payload text,
      created_at timestamp default now()
    )
  SQL

  topic_ids = db.fetch("select id from topics where deleted_at is null and archetype <> 'private_message' order by bumped_at desc limit 250").map { |r| r[:id] }
  user_ids = db.fetch("select id from users where active = true order by last_seen_at desc nulls last limit 200").map { |r| r[:id] }
  category_ids = db.fetch("select id from categories order by id").map { |r| r[:id] }

  rng = Random.new(RNG_SEED)
  200.times do
    db.fetch("select id, title from topics where id = ?", topic_ids.sample(random: rng)).all
    db.fetch("select id, username from users where id = ?", user_ids.sample(random: rng)).all
  end

  metrics = Hash.new { |h, k| h[k] = { calls: 0, seconds: 0.0, rows: 0, bytes: 0 } }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = started + DURATION
  sessions = 0

  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    topic_id = topic_ids.sample(random: rng)
    user_id = user_ids.sample(random: rng)
    category_id = category_ids.sample(random: rng)

    measure(metrics, :latest_page) do
      rows = db.fetch(<<~SQL, category_id, category_id).all
        select t.id, t.title, t.views, t.posts_count, t.bumped_at,
               c.name as category_name,
               u.username as author,
               lu.username as last_poster_username
        from topics t
        join users u on u.id = t.user_id
        join users lu on lu.id = t.last_post_user_id
        left join categories c on c.id = t.category_id
        where t.deleted_at is null
          and t.visible = true
          and t.archetype <> 'private_message'
          and (?::int is null or t.category_id = ?::int)
        order by t.bumped_at desc
        limit 30
      SQL
      materialize_rows(rows, :id, :title, :views, :posts_count, :bumped_at, :category_name, :author, :last_poster_username)
    end

    measure(metrics, :topic_header) do
      rows = db.fetch(<<~SQL, topic_id).all
        select t.id, t.title, t.views, t.like_count, t.posts_count,
               c.name as category_name,
               u.username as author
        from topics t
        join users u on u.id = t.user_id
        left join categories c on c.id = t.category_id
        where t.id = ?
      SQL
      materialize_rows(rows, :id, :title, :views, :like_count, :posts_count, :category_name, :author)
    end

    measure(metrics, :post_stream) do
      rows = db.fetch(<<~SQL, topic_id).all
        select p.id, p.post_number, p.user_id, u.username,
               p.created_at, p.like_count, p.cooked
        from posts p
        join users u on u.id = p.user_id
        where p.topic_id = ?
          and p.deleted_at is null
        order by p.post_number
        limit 20
      SQL
      materialize_rows(rows, :id, :post_number, :user_id, :username, :created_at, :like_count, :cooked)
    end

    measure(metrics, :user_card) do
      rows = db.fetch(<<~SQL, user_id).all
        select u.id, u.username, u.name, u.trust_level,
               count(p.id) as recent_posts,
               coalesce(sum(p.like_count), 0) as recent_likes,
               max(p.created_at) as last_post_at
        from users u
        left join posts p on p.user_id = u.id and p.deleted_at is null
        where u.id = ?
        group by u.id, u.username, u.name, u.trust_level
      SQL
      materialize_rows(rows, :id, :username, :name, :trust_level, :recent_posts, :recent_likes, :last_post_at)
    end

    measure(metrics, :category_counts) do
      rows = db.fetch(<<~SQL).all
        select c.id, c.name, count(t.id) as topic_count, coalesce(sum(t.posts_count), 0) as post_count
        from categories c
        left join topics t on t.category_id = c.id and t.deleted_at is null and t.visible = true
        group by c.id, c.name
        order by topic_count desc, c.id
        limit 20
      SQL
      materialize_rows(rows, :id, :name, :topic_count, :post_count)
    end

    measure(metrics, :temp_write_event) do
      payload = "autosave:#{sessions}"
      db[:bench_events].insert(user_id: user_id, topic_id: topic_id, payload: payload)
      [1, payload.bytesize]
    end

    measure(metrics, :temp_readback) do
      materialize_scalar(db[:bench_events].where(user_id: user_id).count)
    end

    sessions += 1
  end

  finish_report(metrics, started, sessions)
else
  raise "unknown BENCH_MODE=#{MODE.inspect}; use mini_sql, active_record, or sequel"
end

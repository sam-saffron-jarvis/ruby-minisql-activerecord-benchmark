# frozen_string_literal: true

require 'json'
require 'pg'
require 'mini_sql'
require 'active_record'
require 'sequel'
require 'logger'

DURATION = Float(ENV.fetch('BENCH_SECONDS', '15'))
WARMUP = Float(ENV.fetch('BENCH_WARMUP_SECONDS', '3'))
DB = ENV.fetch('PGDATABASE', 'discourse_sql_ft')
USER_NAME = ENV.fetch('PGUSER', 'agent')
DB_HOST = ENV.fetch('PGHOST', nil)
MODE = ENV.fetch('BENCH_MODE') # mini_sql, active_record, sequel
BENCH_CASE = ENV.fetch('BENCH_CASE') # latest_page, topic_header, post_stream, user_card, category_counts, temp_write_event, temp_readback
RNG_SEED = Integer(ENV.fetch('BENCH_SEED', '20260529'))

CASES = %w[
  latest_page
  topic_header
  post_stream
  user_card
  category_counts
  temp_write_event
  temp_readback
].freeze

raise "unknown BENCH_CASE=#{BENCH_CASE.inspect}; use one of #{CASES.join(', ')}" unless CASES.include?(BENCH_CASE)

SCENARIO = 'Static synthetic Discourse-like database; one use case timed independently; result rows are rendered to tab-separated text'

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

def pick_inputs(rng, topic_ids, user_ids, category_ids)
  {
    topic_id: topic_ids.sample(random: rng),
    user_id: user_ids.sample(random: rng),
    category_id: category_ids.sample(random: rng)
  }
end

def measure_loop
  calls = rows = bytes = 0
  elapsed_inside = 0.0
  samples = []

  if WARMUP.positive?
    rng = Random.new(RNG_SEED)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WARMUP
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      yield(rng)
    end
  end

  rng = Random.new(RNG_SEED)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = started + DURATION
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r, b = yield(rng)
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = t1 - t0
    samples << elapsed
    elapsed_inside += elapsed
    calls += 1
    rows += r.to_i
    bytes += b.to_i
  end
  total_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  samples.sort!
  percentile = ->(p) do
    return 0.0 if samples.empty?
    samples[((samples.length - 1) * p).round]
  end

  {
    duration_seconds: total_elapsed,
    calls: calls,
    operations_per_second: calls / total_elapsed,
    avg_ms: calls.positive? ? elapsed_inside * 1000.0 / calls : 0.0,
    p50_ms: percentile.call(0.50) * 1000.0,
    p95_ms: percentile.call(0.95) * 1000.0,
    rows: rows,
    bytes: bytes,
    rows_per_operation: calls.positive? ? rows.to_f / calls : 0.0,
    bytes_per_operation: calls.positive? ? bytes.to_f / calls : 0.0
  }
end

def print_report(result)
  puts JSON.pretty_generate({
    scenario: SCENARIO,
    case: BENCH_CASE,
    mode: MODE,
    ruby: RUBY_VERSION,
    ruby_description: RUBY_DESCRIPTION,
    yjit: defined?(RubyVM::YJIT) ? RubyVM::YJIT.enabled? : false,
    mini_sql: Gem.loaded_specs['mini_sql']&.version&.to_s,
    active_record: Gem.loaded_specs['activerecord']&.version&.to_s,
    sequel: Gem.loaded_specs['sequel']&.version&.to_s,
    pg: Gem.loaded_specs['pg']&.version&.to_s,
    db: DB,
    warmup_seconds: WARMUP,
    result: result
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
    );
    create index if not exists index_temp_bench_events_on_user_id on bench_events(user_id);
  SQL

  topic_ids = conn.query_single("select array_agg(id order by bumped_at desc) from (select id, bumped_at from topics where deleted_at is null and archetype <> 'private_message' order by bumped_at desc limit 250) t").first
  user_ids = conn.query_single("select array_agg(id order by last_seen_at desc nulls last) from (select id, last_seen_at from users where active = true order by last_seen_at desc nulls last limit 200) u").first
  category_ids = conn.query_single("select array_agg(id order by id) from categories").first

  # Keep readback from degenerating into a count over an empty table.
  5000.times do |i|
    conn.exec('insert into bench_events(user_id, topic_id, payload) values(:user_id, :topic_id, :payload)', user_id: user_ids[i % user_ids.length], topic_id: topic_ids[i % topic_ids.length], payload: 'seed')
  end

  result = measure_loop do |rng|
    input = pick_inputs(rng, topic_ids, user_ids, category_ids)
    case BENCH_CASE
    when 'latest_page'
      rows = conn.query(<<~SQL, category_id: input[:category_id])
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
    when 'topic_header'
      rows = conn.query(<<~SQL, id: input[:topic_id])
        select t.id, t.title, t.views, t.like_count, t.posts_count,
               c.name as category_name,
               u.username as author
        from topics t
        join users u on u.id = t.user_id
        left join categories c on c.id = t.category_id
        where t.id = :id
      SQL
      materialize_rows(rows, :id, :title, :views, :like_count, :posts_count, :category_name, :author)
    when 'post_stream'
      rows = conn.query(<<~SQL, topic_id: input[:topic_id])
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
    when 'user_card'
      rows = conn.query(<<~SQL, user_id: input[:user_id])
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
    when 'category_counts'
      rows = conn.query(<<~SQL)
        select c.id, c.name, count(t.id) as topic_count, coalesce(sum(t.posts_count), 0) as post_count
        from categories c
        left join topics t on t.category_id = c.id and t.deleted_at is null and t.visible = true
        group by c.id, c.name
        order by topic_count desc, c.id
        limit 20
      SQL
      materialize_rows(rows, :id, :name, :topic_count, :post_count)
    when 'temp_write_event'
      payload = "autosave:#{rng.rand(1_000_000)}"
      conn.exec('insert into bench_events(user_id, topic_id, payload) values(:user_id, :topic_id, :payload)', user_id: input[:user_id], topic_id: input[:topic_id], payload: payload)
      [1, payload.bytesize]
    when 'temp_readback'
      materialize_scalar(conn.query_single('select count(*) from bench_events where user_id = :user_id', user_id: input[:user_id]).first)
    end
  end

  print_report(result)

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
    );
    create index if not exists index_temp_bench_events_on_user_id on bench_events(user_id);
  SQL

  class BenchEvent < ActiveRecord::Base
    self.table_name = 'bench_events'
  end
  BenchEvent.reset_column_information

  topic_ids = Topic.where(deleted_at: nil).where.not(archetype: 'private_message').order(bumped_at: :desc).limit(250).pluck(:id)
  user_ids = User.where(active: true).order(Arel.sql('last_seen_at desc nulls last')).limit(200).pluck(:id)
  category_ids = Category.order(:id).pluck(:id)
  rows = user_ids.each_with_index.map { |user_id, i| "(#{user_id}, #{topic_ids[i % topic_ids.length]}, 'seed')" }.join(',')
  25.times { ActiveRecord::Base.connection.execute("insert into bench_events(user_id, topic_id, payload) values #{rows}") }

  result = measure_loop do |rng|
    input = pick_inputs(rng, topic_ids, user_ids, category_ids)
    case BENCH_CASE
    when 'latest_page'
      rows = Topic
        .joins(:user)
        .joins('join users last_posters on last_posters.id = topics.last_post_user_id')
        .left_joins(:category)
        .where(deleted_at: nil, visible: true)
        .where.not(archetype: 'private_message')
        .where(category_id: input[:category_id])
        .select('topics.id, topics.title, topics.views, topics.posts_count, topics.bumped_at, categories.name as category_name, users.username as author, last_posters.username as last_poster_username')
        .order(bumped_at: :desc)
        .limit(30)
        .to_a
      materialize_rows(rows, :id, :title, :views, :posts_count, :bumped_at, :category_name, :author, :last_poster_username)
    when 'topic_header'
      rows = Topic.joins(:user).left_joins(:category).where(id: input[:topic_id]).select('topics.id, topics.title, topics.views, topics.like_count, topics.posts_count, categories.name as category_name, users.username as author').to_a
      materialize_rows(rows, :id, :title, :views, :like_count, :posts_count, :category_name, :author)
    when 'post_stream'
      rows = Post.joins(:user).where(topic_id: input[:topic_id], deleted_at: nil).select('posts.id, posts.post_number, posts.user_id, users.username, posts.created_at, posts.like_count, posts.cooked').order(:post_number).limit(20).to_a
      materialize_rows(rows, :id, :post_number, :user_id, :username, :created_at, :like_count, :cooked)
    when 'user_card'
      rows = User.left_joins(:posts).where(id: input[:user_id]).where('posts.deleted_at is null or posts.id is null').select('users.id, users.username, users.name, users.trust_level, count(posts.id) as recent_posts, coalesce(sum(posts.like_count), 0) as recent_likes, max(posts.created_at) as last_post_at').group('users.id, users.username, users.name, users.trust_level').to_a
      materialize_rows(rows, :id, :username, :name, :trust_level, :recent_posts, :recent_likes, :last_post_at)
    when 'category_counts'
      rows = Category.joins('left join topics on topics.category_id = categories.id and topics.deleted_at is null and topics.visible = true').select('categories.id, categories.name, count(topics.id) as topic_count, coalesce(sum(topics.posts_count), 0) as post_count').group('categories.id, categories.name').order(Arel.sql('topic_count desc, categories.id')).limit(20).to_a
      materialize_rows(rows, :id, :name, :topic_count, :post_count)
    when 'temp_write_event'
      payload = "autosave:#{rng.rand(1_000_000)}"
      BenchEvent.create!(user_id: input[:user_id], topic_id: input[:topic_id], payload: payload)
      [1, payload.bytesize]
    when 'temp_readback'
      materialize_scalar(BenchEvent.where(user_id: input[:user_id]).count)
    end
  end

  print_report(result)

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
    );
    create index if not exists index_temp_bench_events_on_user_id on bench_events(user_id);
  SQL

  topic_ids = db.fetch("select id from topics where deleted_at is null and archetype <> 'private_message' order by bumped_at desc limit 250").map { |r| r[:id] }
  user_ids = db.fetch("select id from users where active = true order by last_seen_at desc nulls last limit 200").map { |r| r[:id] }
  category_ids = db.fetch("select id from categories order by id").map { |r| r[:id] }
  5000.times { |i| db[:bench_events].insert(user_id: user_ids[i % user_ids.length], topic_id: topic_ids[i % topic_ids.length], payload: 'seed') }

  result = measure_loop do |rng|
    input = pick_inputs(rng, topic_ids, user_ids, category_ids)
    case BENCH_CASE
    when 'latest_page'
      rows = db.fetch(<<~SQL, input[:category_id], input[:category_id]).all
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
    when 'topic_header'
      rows = db.fetch(<<~SQL, input[:topic_id]).all
        select t.id, t.title, t.views, t.like_count, t.posts_count,
               c.name as category_name,
               u.username as author
        from topics t
        join users u on u.id = t.user_id
        left join categories c on c.id = t.category_id
        where t.id = ?
      SQL
      materialize_rows(rows, :id, :title, :views, :like_count, :posts_count, :category_name, :author)
    when 'post_stream'
      rows = db.fetch(<<~SQL, input[:topic_id]).all
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
    when 'user_card'
      rows = db.fetch(<<~SQL, input[:user_id]).all
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
    when 'category_counts'
      rows = db.fetch(<<~SQL).all
        select c.id, c.name, count(t.id) as topic_count, coalesce(sum(t.posts_count), 0) as post_count
        from categories c
        left join topics t on t.category_id = c.id and t.deleted_at is null and t.visible = true
        group by c.id, c.name
        order by topic_count desc, c.id
        limit 20
      SQL
      materialize_rows(rows, :id, :name, :topic_count, :post_count)
    when 'temp_write_event'
      payload = "autosave:#{rng.rand(1_000_000)}"
      db[:bench_events].insert(user_id: input[:user_id], topic_id: input[:topic_id], payload: payload)
      [1, payload.bytesize]
    when 'temp_readback'
      materialize_scalar(db[:bench_events].where(user_id: input[:user_id]).count)
    end
  end

  print_report(result)
else
  raise "unknown BENCH_MODE=#{MODE.inspect}; use mini_sql, active_record, or sequel"
end

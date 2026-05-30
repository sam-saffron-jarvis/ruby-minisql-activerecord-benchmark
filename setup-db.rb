# frozen_string_literal: true

# Create and populate a synthetic Discourse-like PostgreSQL database for the benchmark.
#
# Required gem:
#   gem install pg
#
# Example:
#   createdb minisql_ar_bench
#   PGDATABASE=minisql_ar_bench ruby setup-db.rb
#
# Tunables:
#   USERS=5000 TOPICS=50000 AVG_POSTS=6 RESET=1 PGDATABASE=minisql_ar_bench ruby setup-db.rb

require "pg"
require "time"
require "tempfile"

DB = ENV.fetch("PGDATABASE", "minisql_ar_bench")
USER_NAME = ENV.fetch("PGUSER", ENV["USER"] || "postgres")
DB_HOST = ENV["PGHOST"]
USERS = Integer(ENV.fetch("USERS", "5000"))
CATEGORIES = Integer(ENV.fetch("CATEGORIES", "32"))
TOPICS = Integer(ENV.fetch("TOPICS", "50000"))
AVG_POSTS = Integer(ENV.fetch("AVG_POSTS", "6"))
RESET = ENV.fetch("RESET", "1") != "0"
SEED = Integer(ENV.fetch("SEED", "20260529"))

conn_args = { dbname: DB, user: USER_NAME }
conn_args[:host] = DB_HOST if DB_HOST && !DB_HOST.empty?
conn = PG.connect(**conn_args)
rng = Random.new(SEED)
now = Time.utc(2026, 5, 29, 0, 0, 0)

puts "database=#{DB} users=#{USERS} categories=#{CATEGORIES} topics=#{TOPICS} avg_posts=#{AVG_POSTS} reset=#{RESET} seed=#{SEED}"

if RESET
  puts "dropping existing benchmark tables"
  conn.exec <<~SQL
    drop table if exists bench_events;
    drop table if exists posts;
    drop table if exists topics;
    drop table if exists categories;
    drop table if exists users;
  SQL
end

puts "creating schema"
conn.exec <<~SQL
  create table if not exists users(
    id integer primary key,
    username varchar(60) not null,
    name varchar,
    created_at timestamp not null,
    updated_at timestamp not null,
    active boolean not null default true,
    last_seen_at timestamp,
    trust_level integer not null default 0
  );

  create table if not exists categories(
    id integer primary key,
    name varchar(50) not null,
    color varchar(6) not null default '0088CC',
    created_at timestamp not null,
    updated_at timestamp not null
  );

  create table if not exists topics(
    id integer primary key,
    title varchar not null,
    last_posted_at timestamp,
    created_at timestamp not null,
    updated_at timestamp not null,
    views integer not null default 0,
    posts_count integer not null default 0,
    user_id integer,
    last_post_user_id integer not null,
    reply_count integer not null default 0,
    deleted_at timestamp,
    highest_post_number integer not null default 0,
    like_count integer not null default 0,
    category_id integer,
    visible boolean not null default true,
    archetype varchar not null default 'regular',
    bumped_at timestamp not null
  );

  create table if not exists posts(
    id integer primary key,
    user_id integer,
    topic_id integer not null,
    post_number integer not null,
    raw text not null,
    cooked text not null,
    created_at timestamp not null,
    updated_at timestamp not null,
    deleted_at timestamp,
    like_count integer not null default 0,
    reads integer not null default 0
  );

  create table if not exists bench_events(
    id serial primary key,
    user_id int,
    topic_id int,
    payload text,
    created_at timestamp default now()
  );
SQL

# Start clean even when RESET=0, so repeated setup runs do not duplicate rows.
puts "truncating benchmark data"
conn.exec "truncate table bench_events, posts, topics, categories, users restart identity"

def copy_rows(conn, table, columns)
  conn.copy_data("copy #{table} (#{columns.join(',')}) from stdin") do
    yield ->(values) { conn.put_copy_data(copy_line(values)) }
  end
end

def copy_file(conn, table, columns, file)
  file.rewind
  conn.copy_data("copy #{table} (#{columns.join(',')}) from stdin") do
    while (chunk = file.read(1024 * 1024))
      conn.put_copy_data(chunk)
    end
  end
end

def copy_line(values)
  values.map { |v| v.nil? ? "\\N" : v.to_s.gsub("\\", "\\\\").gsub("\t", " ").gsub("\n", " ") }.join("\t") + "\n"
end

def ts(base, seconds)
  (base - seconds).strftime("%Y-%m-%d %H:%M:%S")
end

puts "inserting users"
copy_rows(conn, "users", %w[id username name created_at updated_at active last_seen_at trust_level]) do |put|
  1.upto(USERS) do |id|
    created = ts(now, rng.rand(1..40_000_000))
    seen = ts(now, rng.rand(1..8_000_000))
    put.call([id, "user#{id}", "User #{id}", created, seen, rng.rand < 0.94, seen, rng.rand(0..4)])
  end
end

puts "inserting categories"
copy_rows(conn, "categories", %w[id name color created_at updated_at]) do |put|
  1.upto(CATEGORIES) do |id|
    t = ts(now, rng.rand(1..30_000_000))
    put.call([id, "Category #{id}", "%06x" % rng.rand(0xffffff), t, t])
  end
end

puts "inserting topics and posts"
post_id = 0
topic_columns = %w[id title last_posted_at created_at updated_at views posts_count user_id last_post_user_id reply_count deleted_at highest_post_number like_count category_id visible archetype bumped_at]
post_columns = %w[id user_id topic_id post_number raw cooked created_at updated_at deleted_at like_count reads]

topic_file = Tempfile.new("topics.tsv")
post_file = Tempfile.new("posts.tsv")
begin
  1.upto(TOPICS) do |topic_id|
    posts_count = [1, (AVG_POSTS + rng.rand(-2..4))].max
    user_id = rng.rand(1..USERS)
    last_user_id = rng.rand(1..USERS)
    category_id = rng.rand(1..CATEGORIES)
    created = now - rng.rand(1..30_000_000)
    bumped = created + rng.rand(60..2_000_000)
    bumped = now - rng.rand(0..500_000) if bumped > now
    deleted = rng.rand < 0.015 ? ts(now, rng.rand(1..1_000_000)) : nil
    visible = rng.rand >= 0.02
    archetype = rng.rand < 0.03 ? "private_message" : "regular"
    title = "Synthetic topic #{topic_id}: #{%w[postgres ruby rails performance cache query rendering yjit].sample(random: rng)} #{rng.rand(100000)}"

    topic_file.write(copy_line([
      topic_id, title, ts(bumped, 0), ts(created, 0), ts(bumped, 0), rng.rand(0..200_000), posts_count,
      user_id, last_user_id, [posts_count - 1, 0].max, deleted, posts_count, rng.rand(0..250),
      category_id, visible, archetype, ts(bumped, 0)
    ]))

    1.upto(posts_count) do |post_number|
      post_id += 1
      post_user = post_number == 1 ? user_id : rng.rand(1..USERS)
      post_time = created + (post_number * rng.rand(30..20_000))
      raw = "Post #{post_number} in topic #{topic_id}. " + ("This is synthetic benchmark text about Ruby SQL rendering. " * rng.rand(1..5))
      cooked = "<p>#{raw}</p>"
      post_deleted = rng.rand < 0.01 ? ts(now, rng.rand(1..1_000_000)) : nil
      post_file.write(copy_line([post_id, post_user, topic_id, post_number, raw, cooked, ts(post_time, 0), ts(post_time, 0), post_deleted, rng.rand(0..80), rng.rand(0..5000)]))
    end

    puts "  generated topics=#{topic_id} posts=#{post_id}" if (topic_id % 10_000).zero?
  end

  puts "copying topics"
  copy_file(conn, "topics", topic_columns, topic_file)
  puts "copying posts (#{post_id})"
  copy_file(conn, "posts", post_columns, post_file)
ensure
  topic_file.close!
  post_file.close!
end

puts "creating indexes"
conn.exec <<~SQL
  create index if not exists index_users_on_last_seen_at on users(last_seen_at);
  create index if not exists index_users_on_active_last_seen_at on users(active, last_seen_at desc);
  create index if not exists index_topics_on_bumped_public on topics(bumped_at desc) where deleted_at is null and archetype <> 'private_message';
  create index if not exists index_topics_on_category_public on topics(category_id, bumped_at desc) where deleted_at is null and visible = true and archetype <> 'private_message';
  create index if not exists index_topics_on_user_id_deleted_at on topics(user_id) where deleted_at is null;
  create index if not exists index_posts_on_topic_id_post_number on posts(topic_id, post_number) where deleted_at is null;
  create index if not exists index_posts_on_user_id_created_at on posts(user_id, created_at);
  create index if not exists index_bench_events_on_user_id on bench_events(user_id);
SQL

puts "analyzing"
conn.exec "analyze users; analyze categories; analyze topics; analyze posts; analyze bench_events;"

counts = conn.exec("select 'users' as table, count(*) from users union all select 'categories', count(*) from categories union all select 'topics', count(*) from topics union all select 'posts', count(*) from posts order by 1")
counts.each { |row| puts "#{row['table']}=#{row['count']}" }
puts "done"

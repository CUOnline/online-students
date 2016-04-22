require 'csv'
require 'tempfile'
require './online_students_app'

class OnlineStudentsWorker
  @queue = 'online-students'

  def self.query_string
    course_code_pattern = case @params['course-type']
      when 'online'
        'E0[0-9]'
      when 'hybrid'
        'H0[0-9]'
      else
        '(E|H)0[0-9]'
    end

    %{SELECT DISTINCT user_dim.canvas_id
    FROM course_dim
    JOIN enrollment_fact
      ON enrollment_fact.course_id = course_dim.id
      AND enrollment_fact.enrollment_term_id = ?
    JOIN user_dim
      ON enrollment_fact.user_id = user_dim.id
    #{%{LEFT JOIN requests
      ON requests.user_id = user_dim.id
      AND requests.course_id = course_dim.id} if @params['login-filter']}
    WHERE course_dim.code ~ '#{course_code_pattern}'
      AND course_dim.start_at < current_date
    #{%{GROUP BY user_dim.canvas_id
    HAVING COUNT(requests.user_id) = 0;} if @params['login-filter']}}
  end

  def self.perform(params)
    @params = params
    OnlineStudentsApp.resque_log.info("Params: #{params.inspect}")

    # Counters for logging purposes
    cache_miss = 0
    cache_hit = 0

    query_string = self.query_string(params['course-type'], params['login-filter'])
    data = OnlineStudentsApp.canvas_data(query_string, OnlineStudentsApp.shard_id(@params['enrollment-term']))
    results = []

    data.each do |row|
      set_value = nil
      # Check redis first (user:[user id]:email => email)
      if OnlineStudentsApp.redis.get("user:#{row['canvas_id']}:email").nil? ||
         params['refresh-data']

        cache_miss += 1

        # Get email from API if not in redis
        url = "users/#{WolfCore::App.shard_id((row['canvas_id']))}/profile"
        profile = OnlineStudentsApp.canvas_api(:get, url)

        # If no email set in Canvas, cache a value anyway to avoid API next time
        set_value = (profile['primary_email'] || 'n/a').downcase
      else
        cache_hit += 1
      end

      if set_value
        # Expire randomly between 1 and 3 weeks
        # Keeps up to date but prevents rebuilding cache all at once
        expire_seconds = 60 * 60 * 24 * (7..21).to_a.sample
        OnlineStudentsApp.redis.set("user:#{row['canvas_id']}:email", set_value, :ex => expire_seconds)
      end

      results << OnlineStudentsApp.redis.get("user:#{row['canvas_id']}:email")
    end

    self.send_results(results)

    hit_rate = (cache_hit.to_f / (cache_hit + cache_miss).to_f * 100).round(2)
    OnlineStudentsApp.resque_log.info("Total records: #{cache_hit + cache_miss}")
    OnlineStudentsApp.resque_log.info("Cache hit: #{hit_rate} %\n\n")
  end


  def self.send_results(results)
      results = results.reject{ |r| r == 'n/a' || r.nil? || r.empty? }

      output_file = Tempfile.new(['emails', '.csv'])
      output_file.open
      CSV.open(output_file, 'w') do |csv|
        results.each do |r|
          csv << [r]
        end
      end

      # Close to save buffered output, reopen needed to add as attachment
      output_file.close
      output_file.open

      body_str = %{
        Online Student Report
        =====================
        #{Time.now}
        Course type: #{@params['course-type'].capitalize}
        Term: #{OnlineStudentsApp.enrollment_terms[@params['enrollment-term']]}
        Login filter: #{(!(@params['login-filter'].nil?)).to_s.capitalize}
        Total Students #{results.count}
      }

      mail = Mail.new
      mail.from = OnlineStudentsApp.from_email
      mail.to = @params['user_email']
      mail.subject = OnlineStudentsApp.email_subject
      mail.body = body_str
      mail.add_file :filename => 'emails.csv', :content => File.read(output_file.path)
      mail.deliver!

      ensure output_file.close(true) if output_file
  end
end

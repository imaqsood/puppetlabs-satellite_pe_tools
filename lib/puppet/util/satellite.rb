require 'puppet'
require 'puppet/util'
require 'net/http'
require 'net/https'
require 'uri'
require 'yaml'
require 'json'

module Puppet::Util::Satellite
  def settings
    return @settings if @settings
    $settings_file = "/etc/puppetlabs/puppet/satellite_pe_tools.yaml"

    @settings = YAML.load_file($settings_file)
  end

  def create_http
    @uri = URI.parse(satellite_url)
    http = Net::HTTP.new(@uri.host, @uri.port)
    http.use_ssl     = @uri.scheme == 'https'
    if http.use_ssl?
      if settings['ssl_ca'] && !settings['ssl_ca'].empty?
        Puppet.info "Will verify #{satellite_url} SSL identity"

        http.ca_file = settings['ssl_ca']
        raise Puppet::Error, "CA file #{settings['ssl_ca']} does not exist" unless File.exists? settings['ssl_ca']

        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      else
        Puppet.info "Will NOT verify #{satellite_url} SSL identity"
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      if settings['ssl_cert'] && !settings['ssl_cert'].empty? && settings['ssl_key'] && !settings['ssl_key'].empty?
        raise Puppet::Error, "Certificate file #{settings['ssl_cert']} does not exist" unless File.exists? settings['ssl_cert']
        raise Puppet::Error, "Key file #{settings['ssl_key']} does not exist" unless File.exists? settings['ssl_key']

        http.cert = OpenSSL::X509::Certificate.new(File.read(settings['ssl_cert']))
        http.key  = OpenSSL::PKey::RSA.new(File.read(settings['ssl_key']), nil)
      end
    end
    http
  end

  def submit_request(endpoint, body)
    http = create_http
    req = Net::HTTP::Post.new("#{@uri.path}#{endpoint}")
    req.add_field('Accept', 'application/json,version=2' )
    req.content_type = 'application/json'
    req.body = body.to_json
    http.request(req)
  end

  def generate_report
    report = {}
    set_report_format
    report['host'] = self.host
    # Time.to_s behaves differently in 1.8 / 1.9 so we explicity set the 1.9 format
    report['reported_at'] = self.time.utc.strftime("%Y-%m-%d %H:%M:%S UTC")
    report['status'] = metrics_to_hash(self)
    report['metrics'] = m2h(self.metrics)
    report['logs'] = logs_to_array(self.logs)

    report
  end

  private

  METRIC = %w[applied restarted failed failed_restarts skipped pending]

  def metrics_to_hash(report)
    report_status = {}
    metrics = self.metrics

    # find our metric values
    METRIC.each do |m|
      if @format == 0
        report_status[m] = metrics["resources"][m.to_sym] unless metrics["resources"].nil?
      else
        h=translate_metrics_to26(m)
        mv = metrics[h[:type]]
        report_status[m] = mv[h[:name].to_sym] + mv[h[:name].to_s] rescue nil
      end
      report_status[m] ||= 0
    end

    # special fix for false warning about skips
    # sometimes there are skip values, but there are no error messages, we ignore them.
    if report_status["skipped"] > 0 and ((report_status.values.inject(:+)) - report_status["skipped"] == report.logs.size)
      report_status["skipped"] = 0
    end
    # fix for reports that contain no metrics (i.e. failed catalog)
    if @format > 1 and report.respond_to?(:status) and report.status == "failed"
      report_status["failed"] += 1
    end
    # fix for Puppet non-resource errors (i.e. failed catalog fetches before falling back to cache)
    report_status["failed"] += report.logs.find_all {|l| l.source =~ /Puppet$/ && l.level.to_s == 'err' }.count

    return report_status
  end

  def m2h metrics
    h = {}
    metrics.each do |title, mtype|
      h[mtype.name] ||= {}
      mtype.values.each{|m| h[mtype.name].merge!({m[0].to_s => m[2]})}
    end
    return h
  end

  def logs_to_array logs
    h = []
    logs.each do |log|
      # skipping debug messages, we dont want them in Foreman's db
      next if log.level == :debug

      # skipping catalog summary run messages, we dont want them in Foreman's db
      next if log.message =~ /^Finished catalog run in \d+.\d+ seconds$/

      # Match Foreman's slightly odd API format...
      l = { 'log' => { 'sources' => {}, 'messages' => {} } }
      l['log']['level'] = log.level.to_s
      l['log']['messages']['message'] = log.message
      l['log']['sources']['source'] = log.source
      h << l
    end
    return h
  end

  # The metrics layout has changed in Puppet 2.6.x release,
  # this method attempts to align the bit value metrics and the new name scheme in 2.6.x
  # returns a hash of { :type => "metric type", :name => "metric_name"}
  def translate_metrics_to26 metric
    case metric
    when "applied"
      case @format
      when 0..1
        { :type => "total", :name => :changes}
      else
        { :type => "changes", :name => "total"}
      end
    when "failed_restarts"
      case @format
      when 0..1
        { :type => "resources", :name => metric}
      else
        { :type => "resources", :name => "failed_to_restart"}
      end
    when "pending"
      { :type => "events", :name => "noop" }
    else
      { :type => "resources", :name => metric}
    end
  end

  def set_report_format
    @format ||= case
                when self.instance_variables.detect {|v| v.to_s == "@environment"}
                  @format = 3
                when self.instance_variables.detect {|v| v.to_s == "@report_format"}
                  @format = 2
                when self.instance_variables.detect {|v| v.to_s == "@resource_statuses"}
                  @format = 1
                else
                  @format = 0
                end
  end


  def satellite_url
    settings['url'] || raise(Puppet::Error, "Must provide url parameter to satellite class")
  end
end

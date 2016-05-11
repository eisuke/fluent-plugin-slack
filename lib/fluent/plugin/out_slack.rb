require_relative 'slack_client'

module Fluent
  class SlackOutput < Fluent::BufferedOutput
    Fluent::Plugin.register_output('buffered_slack', self) # old version compatiblity
    Fluent::Plugin.register_output('slack', self)

    # For fluentd v0.12.16 or earlier
    class << self
      unless method_defined?(:desc)
        def desc(description)
        end
      end
    end

    include SetTimeKeyMixin
    include SetTagKeyMixin

    config_set_default :include_time_key, true
    config_set_default :include_tag_key, true

    desc <<-DESC
Incoming Webhook URI (Required for Incoming Webhook mode).
See: https://api.slack.com/incoming-webhooks
DESC
    config_param :webhook_url,          :string, default: nil
    desc <<-DESC
Slackbot URI (Required for Slackbot mode).
See https://api.slack.com/slackbot.
NOTE: most of optional parameters such as `username`, `color`, `icon_emoji`,
`icon_url`, and `title` are not available for this mode, but Desktop Notification
via Highlight Words works with only this mode.
DESC
    config_param :slackbot_url,         :string, default: nil
    desc <<-DESC
Token for Web API (Required for Web API mode). See: https://api.slack.com/web.
DESC
    config_param :token,                :string, default: nil
    desc "Name of bot."
    config_param :username,             :string, default: nil
    desc <<-DESC
Color to use such as `good` or `bad`.
See Color section of https://api.slack.com/docs/attachments.
NOTE: This parameter must not be specified to receive Desktop Notification
via Mentions in cases of Incoming Webhook and Slack Web API.
DESC
    config_param :color,                :string, default: nil
    desc <<-DESC
Emoji to use as the icon.
Either of `icon_emoji` or `icon_url` can be specified.
DESC
    config_param :icon_emoji,           :string, default: nil
    desc <<-DESC
Url to an image to use as the icon.
Either of `icon_emoji` or `icon_url` can be specified.
DESC
    config_param :icon_url,             :string, default: nil
    desc "Enable formatting. See: https://api.slack.com/docs/formatting."
    config_param :mrkdwn,               :bool,   default: true
    desc <<-DESC
Find and link channel names and usernames.
NOTE: This parameter must be `true` to receive Desktop Notification
via Mentions in cases of Incoming Webhook and Slack Web API.
DESC
    config_param :link_names,           :bool,   default: true
    desc <<-DESC
Change how messages are treated. `none` or `full` can be specified.
See Parsing mode section of https://api.slack.com/docs/formatting.
DESC
    config_param :parse,                :string, default: nil
    desc <<-DESC
Create channels if not exist. Not available for Incoming Webhook mode
(since Incoming Webhook is specific to a channel).
A web api token for Normal User is required.
(Bot User can not create channels. See https://api.slack.com/bot-users)
DESC
    config_param :auto_channels_create, :bool,   default: false
    desc "https proxy url such as https://proxy.foo.bar:443"
    config_param :https_proxy,          :string, default: nil

    desc "channel to send messages (without first '#')."
    config_param :channel,              :string
    desc <<-DESC
Keys used to format channel.
%s will be replaced with value specified by channel_keys if this option is used.
DESC
    config_param :channel_keys,         default: nil do |val|
      val.split(',')
    end
    desc <<-DESC
Title format.
%s will be replaced with value specified by title_keys.
Title is created from the first appeared record on each tag.
NOTE: This parameter must **not** be specified to receive Desktop Notification
via Mentions in cases of Incoming Webhook and Slack Web API.
DESC
    config_param :title,                :string, default: nil
    desc "Keys used to format the title."
    config_param :title_keys,           default: nil do |val|
      val.split(',')
    end
    desc <<-DESC
Message format.
%s will be replaced with value specified by message_keys.
DESC
    config_param :message,              :string, default: nil
    desc "Keys used to format messages."
    config_param :message_keys,         default: nil do |val|
      val.split(',')
    end

    # for test
    attr_reader :slack, :time_format, :localtime, :timef, :mrkdwn_in, :post_message_opts

    OPTIONAL_ATTACHEMENT_FIELDS = %i[fallback color pretext auther_name author_link author_icon title_link image_url thumb_url]

    def initialize
      super
      require 'uri'
    end

    def configure(conf)
      conf['time_format'] ||= '%H:%M:%S' # old version compatiblity
      conf['localtime'] ||= true unless conf['utc']

      super

      @channel = URI.unescape(@channel) # old version compatibility
      @channel = '#' + @channel unless @channel.start_with?('#')

      if @webhook_url
        if @webhook_url.empty?
          raise Fluent::ConfigError.new("`webhook_url` is an empty string")
        end
        @slack = Fluent::SlackClient::IncomingWebhook.new(@webhook_url)
      elsif @slackbot_url
        if @slackbot_url.empty?
          raise Fluent::ConfigError.new("`slackbot_url` is an empty string")
        end
        if @username or @color or @icon_emoji or @icon_url
          log.warn "out_slack: `username`, `color`, `icon_emoji`, `icon_url` parameters are not available for Slackbot Remote Control"
        end
        @slack = Fluent::SlackClient::Slackbot.new(@slackbot_url)
      elsif @token
        if @token.empty?
          raise Fluent::ConfigError.new("`token` is an empty string")
        end
        @slack = Fluent::SlackClient::WebApi.new
      else
        raise Fluent::ConfigError.new("One of `webhook_url` or `slackbot_url`, or `token` is required")
      end
      @slack.log = log
      @slack.debug_dev = log.out if log.level <= Fluent::Log::LEVEL_TRACE

      if @https_proxy
        @slack.https_proxy = @https_proxy
      end

      @message      ||= '%s'
      @message_keys ||= %w[message]
      begin
        @message % (['1'] * @message_keys.length)
      rescue ArgumentError
        raise Fluent::ConfigError, "string specifier '%s' for `message`  and `message_keys` specification mismatch"
      end
      if @title and @title_keys
        begin
          @title % (['1'] * @title_keys.length)
        rescue ArgumentError
          raise Fluent::ConfigError, "string specifier '%s' for `title` and `title_keys` specification mismatch"
        end
      end
      if @channel_keys
        begin
          @channel % (['1'] * @channel_keys.length)
        rescue ArgumentError
          raise Fluent::ConfigError, "string specifier '%s' for `channel` and `channel_keys` specification mismatch"
        end
      end

      if @icon_emoji and @icon_url
        raise Fluent::ConfigError, "either of `icon_emoji` or `icon_url` can be specified"
      end

      if @mrkdwn
        # Enable markdown for attachments. See https://api.slack.com/docs/formatting
        @mrkdwn_in = %w[text pretext]
      end

      if @parse and !%w[none full].include?(@parse)
        raise Fluent::ConfigError, "`parse` must be either of `none` or `full`"
      end

      @post_message_opts = {}
      if @auto_channels_create
        raise Fluent::ConfigError, "`token` parameter is required to use `auto_channels_create`" unless @token
        @post_message_opts = {auto_channels_create: true}
      end
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      begin
        payloads = build_payloads(chunk)
        payloads.each {|payload| @slack.post_message(payload, @post_message_opts) }
      rescue Timeout::Error => e
        log.warn "out_slack:", :error => e.to_s, :error_class => e.class.to_s
        raise e # let Fluentd retry
      rescue => e
        log.error "out_slack:", :error => e.to_s, :error_class => e.class.to_s
        log.warn_backtrace e.backtrace
        # discard. @todo: add more retriable errors
      end
    end

    private

    def build_payloads(chunk)
      if @title || @color
        build_attachement_payloads(chunk)
      else
        build_plain_payloads(chunk)
      end
    end

    def common_payload
      return @common_payload if @common_payload
      @common_payload = {}
      @common_payload[:username]   = @username   if @username
      @common_payload[:icon_emoji] = @icon_emoji if @icon_emoji
      @common_payload[:icon_url]   = @icon_url   if @icon_url
      @common_payload[:mrkdwn]     = @mrkdwn     if @mrkdwn
      @common_payload[:link_names] = @link_names if @link_names
      @common_payload[:parse]      = @parse      if @parse
      @common_payload[:token]      = @token      if @token
      @common_payload
    end

    def common_attachment
      return @common_attachment if @common_attachment
      @common_attachment = {}
      @common_attachment[:color]     = @color     if @color
      @common_attachment[:mrkdwn_in] = @mrkdwn_in if @mrkdwn_in
      @common_attachment
    end

    def build_attachement_payloads(chunk)
      ch_records = {}

      chunk.msgpack_each do |tag, time, record|
        channel = build_channel(record)
        ch_records[channel] ||= []
        ch_records[channel] << record
      end

      ch_records.map do |channel, records|
        attachments = records.map do |record|
          attachment = common_attachment.dup
          attachment[:text] = build_message(record)

          attachment[:fallback] = ''
          if @title
            attachment[:title] = build_title(record)
            attachment[:fallback] = "#{attachment[:title]} "
          end
          attachment[:fallback] << attachment[:text]

          OPTIONAL_ATTACHEMENT_FIELDS.each do |name|
            if record[name]
              attachment[name] = record[name]
            end
          end
          attachment
        end

        { channel: channel, attachments: attachments }.merge(common_payload)
      end
    end

    def build_plain_payloads(chunk)
      messages = {}
      chunk.msgpack_each do |tag, time, record|
        channel = build_channel(record)
        messages[channel] ||= ''
        messages[channel] << "#{build_message(record)}\n"
      end
      messages.map do |channel, text|
        {
          channel: channel,
          text:    text,
        }.merge(common_payload)
      end
    end

    def build_message(record)
      values = fetch_keys(record, @message_keys)
      @message % values
    end

    def build_title(record)
      return @title unless @title_keys

      values = fetch_keys(record, @title_keys)
      @title % values
    end

    def build_channel(record)
      return @channel unless @channel_keys

      values = fetch_keys(record, @channel_keys)
      @channel % values
    end

    def fetch_keys(record, keys)
      Array(keys).map do |key|
        begin
          record.fetch(key).to_s
        rescue KeyError
          log.warn "out_slack: the specified key '#{key}' not found in record. [#{record}]"
          ''
        end
      end
    end
  end
end

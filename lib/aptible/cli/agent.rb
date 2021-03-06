require 'base64'
require 'uri'

require 'aptible/auth'
require 'thor'
require 'json'
require 'chronic_duration'

require_relative 'helpers/ssh'
require_relative 'helpers/token'
require_relative 'helpers/operation'
require_relative 'helpers/environment'
require_relative 'helpers/app'
require_relative 'helpers/database'
require_relative 'helpers/app_or_database'
require_relative 'helpers/vhost'
require_relative 'helpers/vhost/option_set_builder'
require_relative 'helpers/tunnel'
require_relative 'helpers/system'
require_relative 'helpers/security_key'

require_relative 'subcommands/apps'
require_relative 'subcommands/config'
require_relative 'subcommands/db'
require_relative 'subcommands/domains'
require_relative 'subcommands/logs'
require_relative 'subcommands/ps'
require_relative 'subcommands/rebuild'
require_relative 'subcommands/deploy'
require_relative 'subcommands/restart'
require_relative 'subcommands/services'
require_relative 'subcommands/ssh'
require_relative 'subcommands/backup'
require_relative 'subcommands/operation'
require_relative 'subcommands/inspect'
require_relative 'subcommands/endpoints'

module Aptible
  module CLI
    class Agent < Thor
      include Thor::Actions

      include Helpers::Token
      include Helpers::Ssh
      include Helpers::System
      include Subcommands::Apps
      include Subcommands::Config
      include Subcommands::DB
      include Subcommands::Domains
      include Subcommands::Logs
      include Subcommands::Ps
      include Subcommands::Rebuild
      include Subcommands::Deploy
      include Subcommands::Restart
      include Subcommands::Services
      include Subcommands::SSH
      include Subcommands::Backup
      include Subcommands::Operation
      include Subcommands::Inspect
      include Subcommands::Endpoints

      # Forward return codes on failures.
      def self.exit_on_failure?
        true
      end

      def initialize(*)
        nag_toolbelt unless toolbelt?
        Aptible::Resource.configure { |conf| conf.user_agent = version_string }
        super
      end

      desc 'version', 'Print Aptible CLI version'
      def version
        Formatter.render(Renderer.current) do |root|
          root.keyed_object('version') do |node|
            node.value('version', version_string)
          end
        end
      end

      desc 'login', 'Log in to Aptible'
      option :email
      option :password
      option :lifetime, desc: 'The duration the token should be valid for ' \
                              '(example usage: 24h, 1d, 600s, etc.)'
      option :otp_token, desc: 'A token generated by your second-factor app'
      option :sso, desc: 'Use a token from a Single Sign On login on the ' \
                         'dashboard'
      def login
        if options[:sso]
          begin
            token = options[:sso]
            token = ask('Paste token copied from Dashboard:') if token == 'sso'
            Base64.urlsafe_decode64(token.split('.').first)
            save_token(token)
            CLI.logger.info "Token written to #{token_file}"
            return
          rescue StandardError
            raise Thor::Error, 'Invalid token provided for SSO'
          end
        end

        email = options[:email] || ask('Email: ')
        password = options[:password] || ask_then_line(
          'Password: ', echo: false
        )

        token_options = { email: email, password: password }

        otp_token = options[:otp_token]
        token_options[:otp_token] = otp_token if otp_token

        begin
          lifetime = '1w'
          lifetime = '12h' if token_options[:otp_token] || token_options[:u2f]
          lifetime = options[:lifetime] if options[:lifetime]

          duration = ChronicDuration.parse(lifetime)
          if duration.nil?
            raise Thor::Error, "Invalid token lifetime requested: #{lifetime}"
          end

          token_options[:expires_in] = duration
          token = Aptible::Auth::Token.create(token_options)
        rescue OAuth2::Error => e
          # If a MFA is require but a token wasn't provided,
          # prompt the user for MFA authentication and retry
          if e.code != 'otp_token_required'
            raise Thor::Error, 'Could not authenticate with given ' \
                               "credentials: #{e.code}"
          end

          u2f = (e.response.parsed['exception_context'] || {})['u2f']

          q = Queue.new
          mfa_threads = []

          # If the user has added a security key and their computer supports it,
          # allow them to use it
          if u2f && !which('u2f-host').nil?
            origin = Aptible::Auth::Resource.new.get.href
            app_id = Aptible::Auth::Resource.new.utf_trusted_facets.href

            challenge = u2f.fetch('challenge')

            devices = u2f.fetch('devices').map do |dev|
              Helpers::SecurityKey::Device.new(
                dev.fetch('version'), dev.fetch('key_handle')
              )
            end

            puts 'Enter your 2FA token or touch your Security Key once it ' \
                 'starts blinking.'

            mfa_threads << Thread.new do
              token_options[:u2f] = Helpers::SecurityKey.authenticate(
                origin, app_id, challenge, devices
              )

              puts ''

              q.push(nil)
            end
          end

          mfa_threads << Thread.new do
            token_options[:otp_token] = options[:otp_token] || ask(
              '2FA Token: '
            )

            q.push(nil)
          end

          # Block until one of the threads completes
          q.pop

          mfa_threads.each do |thr|
            sleep 0.5 until thr.status != 'run'
            thr.kill
          end.each(&:join)

          retry
        end

        save_token(token.access_token)
        CLI.logger.info "Token written to #{token_file}"

        lifetime_format = { units: 2, joiner: ', ' }
        token_lifetime = (token.expires_at - token.created_at).round
        expires_in = ChronicDuration.output(token_lifetime, lifetime_format)
        CLI.logger.info "This token will expire after #{expires_in} " \
                        '(use --lifetime to customize)'
      end

      private

      def deprecated(msg)
        CLI.logger.warn([
          "DEPRECATION NOTICE: #{msg}",
          'Please contact support@aptible.com with any questions.'
        ].join("\n"))
      end

      def nag_toolbelt
        # If you're reading this, it's possible you decided to not use the
        # toolbelt and are a looking for a way to disable this warning. Look no
        # further: to do so, edit the file `.aptible/nag_toolbelt` and put a
        # timestamp far into the future. For example, writing 1577836800 will
        # disable the warning until 2020.
        nag_file = File.join ENV['HOME'], '.aptible', 'nag_toolbelt'
        nag_frequency = 12.hours

        last_nag = begin
                     Integer(File.read(nag_file))
                   rescue Errno::ENOENT, ArgumentError
                     0
                   end

        now = Time.now.utc.to_i

        if last_nag < now - nag_frequency
          CLI.logger.warn([
            'You have installed the Aptible CLI from source.',
            'This is not recommended: some functionality may not work!',
            'Review this support topic for more information:',
            'https://www.aptible.com/support/topics/cli/how-to-install-cli/'
          ].join("\n"))

          FileUtils.mkdir_p(File.dirname(nag_file))
          File.open(nag_file, 'w', 0o600) { |f| f.write(now.to_s) }
        end
      end

      def version_string
        bits = [
          'aptible-cli',
          "v#{Aptible::CLI::VERSION}"
        ]
        bits << 'toolbelt' if toolbelt?
        bits.join ' '
      end

      def toolbelt?
        ENV['APTIBLE_TOOLBELT']
      end
    end
  end
end

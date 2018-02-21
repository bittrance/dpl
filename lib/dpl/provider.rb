require 'dpl/error'
require 'dpl/version'
require 'fileutils'

module DPL
  class Provider
    include FileUtils

    PROVIDERS = {
      'Anynines'            => 'anynines',
      'Appfog'              => 'appfog',
      'Atlas'               => 'atlas',
      'AzureWebApps'        => 'azure_webapps',
      'Bintray'             => 'bintray',
      'BitBalloon'          => 'bitballoon',
      'BluemixCloudFoundry' => 'bluemix_cloud_foundry',
      'Boxfuse'             => 'boxfuse',
      'Catalyze'            => 'catalyze',
      'ChefSupermarket'     => 'chef_supermarket',
      'Cloud66'             => 'cloud66',
      'CloudFiles'          => 'cloud_files',
      'CloudFoundry'        => 'cloud_foundry',
      'CodeDeploy'          => 'cloud_deploy',
      'Deis'                => 'deis',
      'Divshot'             => 'divshot',
      'ElasticBeanstalk'    => 'elastic_beanstalk',
      'EngineYard'          => 'engine_yard',
      'Firebase'            => 'firebase',
      'GAE'                 => 'gae',
      'GCS'                 => 'gcs',
      'Hackage'             => 'hackage',
      'Heroku'              => 'heroku',
      'Lambda'              => 'lambda',
      'Launchpad'           => 'launchpad',
      'Modulus'             => 'modulus',
      'Nodejitsu'           => 'nodejitsu',
      'NPM'                 => 'npm',
      'Openshift'           => 'openshift',
      'OpsWorks'            => 'ops_works',
      'Packagecloud'        => 'packagecloud',
      'Pages'               => 'pages',
      'PuppetForge'         => 'puppet_forge',
      'PyPI'                => 'pypi',
      'Releases'            => 'releases',
      'RubyGems'            => 'rubygems',
      'S3'                  => 's3',
      'Scalingo'            => 'scalingo',
      'Script'              => 'script',
      'Surge'               => 'surge',
      'TestFairy'           => 'testfairy',
      'Transifex'           => 'transifex',
    }

    def self.new(context, options)
      return super if self < Provider

      context.fold("Installing deploy dependencies") do
        begin
          opt_lower = super.option(:provider).to_s.downcase
          opt = opt_lower.gsub(/[^a-z0-9]/, '')
          name = PROVIDERS.keys.detect { |p| p.to_s.downcase == opt }.tap {|x| puts "name: #{x}"}
          raise Error, "could not find provider %p" % opt unless name

          require "dpl/provider/#{opt_lower}"
          provider = const_get(name).new(context, options)
        rescue NameError, LoadError => e
          if /uninitialized constant DPL::Provider::(?<provider_wanted>\S+)/ =~ e.message
            provider_name = PROVIDERS[provider_wanted]
          end
          install_cmd = "gem install dpl-#{PROVIDERS[provider_name] || opt} -v #{ENV['DPL_VERSION'] || DPL::VERSION}"

          if File.exist?(local_gem = File.join(Dir.pwd, "dpl-#{PROVIDERS[provider_name] || opt_lower}-#{ENV['DPL_VERSION'] || DPL::VERSION}.gem"))
            install_cmd = "gem install #{local_gem}"
          end

          context.shell(install_cmd.tap {|cmd| $stderr.puts "Running #{cmd}"})
          Gem.clear_paths

          require "dpl/provider/#{opt_lower}"
          provider = const_get(name).new(context, options)
        rescue DPL::Error
          provider = const_get(opt.capitalize).new(context, options) if opt_lower
        end

        if options[:no_deploy]
          def provider.deploy; end
        else
          provider.install_deploy_dependencies if provider.respond_to? :install_deploy_dependencies
        end

        provider
      end
    end

    def self.experimental(name)
      puts "", "!!! #{name} support is experimental !!!", ""
    end

    def self.deprecated(*lines)
      puts ''
      lines.each do |line|
        puts "\e[31;1m#{line}\e[0m"
      end
      puts ''
    end

    def self.context
      self
    end

    def self.shell(command, options = {})
      system(command)
    end

    def self.apt_get(name, command = name)
      context.shell("sudo apt-get -qq install #{name}", retry: true) if `which #{command}`.chop.empty?
    end

    def self.pip(name, command = name, version = nil)
      if version
        puts "pip install --user #{name}==#{version}"
        context.shell("pip uninstall --user -y #{name}") unless `which #{command}`.chop.empty?
        context.shell("pip install --user #{name}==#{version}", retry: true)
      else
        puts "pip install --user #{name}"
        context.shell("pip install --user #{name}", retry: true) if `which #{command}`.chop.empty?
      end
      context.shell("export PATH=$PATH:$HOME/.local/bin")
    end

    def self.npm_g(name, command = name)
      context.shell("npm install -g #{name}", retry: true) if `which #{command}`.chop.empty?
    end

    attr_reader :context, :options

    def initialize(context, options)
      @context, @options = context, options
      context.env['GIT_HTTP_USER_AGENT'] = user_agent(git: `git --version`[/[\d\.]+/])
    end

    def user_agent(*strings)
      strings.unshift "dpl/#{DPL::VERSION}"
      strings.unshift "travis/0.1.0" if context.env['TRAVIS']
      strings = strings.flat_map { |e| Hash === e ? e.map { |k,v| "#{k}/#{v}" } : e }
      strings.join(" ").gsub(/\s+/, " ").strip
    end

    def option(name, *alternatives)
      options.fetch(name) do
        alternatives.any? ? option(*alternatives) : raise(Error, "missing #{name}")
      end
    end

    def deploy
      setup_git_credentials
      rm_rf ".dpl"
      mkdir_p ".dpl"

      context.fold("Preparing deploy") do
        check_auth
        check_app

        if needs_key?
          create_key(".dpl/id_rsa")
          setup_key(".dpl/id_rsa.pub")
          setup_git_ssh(".dpl/git-ssh", ".dpl/id_rsa")
        end

        cleanup
      end

      context.fold("Deploying application") { push_app }

      Array(options[:run]).each do |command|
        if command == 'restart'
          context.fold("Restarting application") { restart }
        else
          context.fold("Running %p" % command) { run(command) }
        end
      end
    ensure
      if needs_key?
        remove_key rescue nil
      end
      uncleanup
    end

    def sha
      @sha ||= context.env['TRAVIS_COMMIT'] || `git rev-parse HEAD`.strip
    end

    def commit_msg
      @commit_msg ||= %x{git log #{sha} -n 1 --pretty=%B}.strip
    end

    def cleanup
      return if options[:skip_cleanup]
      context.shell "mv .dpl ~/dpl"
      log "Cleaning up git repository with `git stash --all`. " \
        "If you need build artifacts for deployment, set `deploy.skip_cleanup: true`. " \
        "See https://docs.travis-ci.com/user/deployment/#Uploading-Files."
      context.shell "git stash --all"
      context.shell "mv ~/dpl .dpl"
    end

    def uncleanup
      return if options[:skip_cleanup]
      context.shell "git stash pop"
    end

    def needs_key?
      true
    end

    def check_app
    end

    def create_key(file)
      context.shell "ssh-keygen -t rsa -N \"\" -C #{option(:key_name)} -f #{file}"
    end

    def setup_git_credentials
      context.shell "git config user.email >/dev/null 2>/dev/null || git config user.email `whoami`@localhost"
      context.shell "git config user.name >/dev/null 2>/dev/null || git config user.name `whoami`@localhost"
    end

    def setup_git_ssh(path, key_path)
      key_path = File.expand_path(key_path)
      path     = File.expand_path(path)

      File.open(path, 'w') do |file|
        file.write "#!/bin/sh\n"
        file.write "exec ssh -o StrictHostKeychecking=no -o CheckHostIP=no -o UserKnownHostsFile=/dev/null -i #{key_path} -- \"$@\"\n"
      end

      chmod(0740, path)
      context.env['GIT_SSH'] = path
    end

    def detect_encoding?
      options[:detect_encoding]
    end

    def default_text_charset?
      options[:default_text_charset]
    end

    def default_text_charset
      options[:default_text_charset].downcase
    end

    def install_deploy_dependencies
    end

    def encoding_for(path)
      file_cmd_output = `file '#{path}'`
      case file_cmd_output
      when /gzip compressed/
        'gzip'
      when /compress'd/
        'compress'
      when /text/
        'text'
      when /data/
        # Shrugs?
      end
    end

    def log(message)
      $stderr.puts(message)
    end

    def warn(message)
      log "\e[31;1m#{message}\e[0m"
    end

    def run(command)
      error "running commands not supported"
    end

    def error(message)
      raise Error, message
    end
  end
end

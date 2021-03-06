require 'puppet/application'
require 'puppet/util/network_device'

class Puppet::Application::Device < Puppet::Application

  run_mode :agent

  attr_accessor :args, :agent, :host

  def app_defaults
    super.merge({
      :catalog_terminus => :rest,
      :catalog_cache_terminus => :json,
      :node_terminus => :rest,
      :facts_terminus => :network_device,
    })
  end

  def preinit
    # Do an initial trap, so that cancels don't get a stack trace.
    Signal.trap(:INT) do
      $stderr.puts _("Cancelling startup")
      exit(0)
    end

    {
      :waitforcert => nil,
      :detailed_exitcodes => false,
      :verbose => false,
      :debug => false,
      :centrallogs => false,
      :setdest => false,
      :target => nil,
    }.each do |opt,val|
      options[opt] = val
    end

    @args = {}
  end

  option("--centrallogging")
  option("--debug","-d")
  option("--verbose","-v")

  option("--detailed-exitcodes") do |arg|
    options[:detailed_exitcodes] = true
  end

  option("--logdest DEST", "-l DEST") do |arg|
    handle_logdest_arg(arg)
  end

  option("--waitforcert WAITFORCERT", "-w") do |arg|
    options[:waitforcert] = arg.to_i
  end

  option("--port PORT","-p") do |arg|
    @args[:Port] = arg
  end

  option("--target DEVICE", "-t") do |arg|
    options[:target] = arg.to_s
  end

  def summary
    _("Manage remote network devices")
  end

  def help
      <<-HELP

puppet-device(8) -- #{summary}
========

SYNOPSIS
--------
Retrieves catalogs from the Puppet master and applies them to remote devices. 

This subcommand can be run manually; or periodically using cron,
a scheduled task, or a similar tool.


USAGE
-----
  puppet device [-d|--debug] [--detailed-exitcodes] [--deviceconfig <file>]
                [-h|--help] [-l|--logdest syslog|<file>|console]
                [-v|--verbose] [-w|--waitforcert <seconds>]
                [-t|--target <device>] [--user=<user>] [-V|--version]


DESCRIPTION
-----------
Devices require a proxy Puppet agent to request certificates, collect facts,
retrieve and apply catalogs, and store reports.


USAGE NOTES
-----------
Devices managed by the puppet-device subcommand on a Puppet agent are 
configured in device.conf, which is located at $confdir/device.conf by default, 
and is configurable with the $deviceconfig setting. 

The device.conf file is an INI-like file, with one section per device:

[<DEVICE_CERTNAME>]
type <TYPE>
url <URL>
debug

The section name specifies the certname of the device. 

The values for the type and url properties are specific to each type of device.

The optional debug property specifies transport-level debugging,
and is limited to telnet and ssh transports.

See https://docs.puppet.com/puppet/latest/config_file_device.html for details.


OPTIONS
-------
Note that any setting that's valid in the configuration file is also a valid 
long argument. For example, 'server' is a valid configuration parameter, so 
you can specify '--server <servername>' as an argument.

* --debug:
  Enable full debugging.

* --detailed-exitcodes:
  Provide transaction information via exit codes. If this is enabled, an exit
  code of '1' means at least one device had a compile failure, an exit code of
  '2' means at least one device had resource changes, and an exit code of '4'
  means at least one device had resource failures. Exit codes of '3', '5', '6',
  or '7' means that a bitwise combination of the preceding exit codes happened.

* --deviceconfig:
  Path to the device config file for puppet device.
  Default: $confdir/device.conf

* --help:
  Print this help message

* --logdest:
  Where to send log messages. Choose between 'syslog' (the POSIX syslog
  service), 'console', or the path to a log file. If debugging or verbosity is
  enabled, this defaults to 'console'. Otherwise, it defaults to 'syslog'.

  A path ending with '.json' will receive structured output in JSON format. The
  log file will not have an ending ']' automatically written to it due to the
  appending nature of logging. It must be appended manually to make the content
  valid JSON.

* --target:
  Target a specific device/certificate in the device.conf. Doing so will perform a
  device run against only that device/certificate.

* --user:
  The user to run as. '--user=root' is required, even when run as root,
  for runs that create device certificates or keys.

* --verbose:
  Turn on verbose reporting.

* --waitforcert:
  This option only matters for daemons that do not yet have certificates
  and it is enabled by default, with a value of 120 (seconds).  This causes
  +puppet agent+ to connect to the server every 2 minutes and ask it to sign a
  certificate request.  This is useful for the initial setup of a puppet
  client.  You can turn off waiting for certificates by specifying a time of 0.


EXAMPLE
-------
      $ puppet device --server puppet.domain.com

AUTHOR
------
Brice Figureau


COPYRIGHT
---------
Copyright (c) 2011 Puppet Inc., LLC
Licensed under the Apache 2.0 License
      HELP
    end


  def main
    vardir = Puppet[:vardir]
    confdir = Puppet[:confdir]
    certname = Puppet[:certname]

    env = Puppet.lookup(:environments).get(Puppet[:environment])
    returns = Puppet.override(:current_environment => env, :loaders => Puppet::Pops::Loaders.new(env)) do
      # find device list
      require 'puppet/util/network_device/config'
      devices = Puppet::Util::NetworkDevice::Config.devices.dup
      if options[:target]
        devices.select! { |key, value| key == options[:target] }
      end
      if devices.empty?
        if options[:target]
          Puppet.err _("Target device / certificate '%{target}' not found in %{config}") % { target: options[:target], config: Puppet[:deviceconfig] }
        else
          Puppet.err _("No device found in %{config}") % { config: Puppet[:deviceconfig] }
          exit(1)
        end
      end
      devices.collect do |devicename,device|
        begin
          device_url = URI.parse(device.url)
          # Handle nil scheme & port
          scheme = "#{device_url.scheme}://" if device_url.scheme
          port = ":#{device_url.port}" if device_url.port
          Puppet.info _("starting applying configuration to %{target} at %{scheme}%{url_host}%{port}%{url_path}") % { target: device.name, scheme: scheme, url_host: device_url.host, port: port, url_path: device_url.path }

          # override local $vardir and $certname
          Puppet[:confdir] = ::File.join(Puppet[:devicedir], device.name)
          Puppet[:vardir] = ::File.join(Puppet[:devicedir], device.name)
          Puppet[:certname] = device.name

          # this will reload and recompute default settings and create the devices sub vardir, or we hope so :-)
          Puppet.settings.use :main, :agent, :ssl

          # this init the device singleton, so that the facts terminus
          # and the various network_device provider can use it
          Puppet::Util::NetworkDevice.init(device)

          # ask for a ssl cert if needed, but at least
          # setup the ssl system for this device.
          setup_host

          require 'puppet/configurer'
          configurer = Puppet::Configurer.new
          configurer.run(:network_device => true, :pluginsync => Puppet::Configurer.should_pluginsync?)
        rescue => detail
          Puppet.log_exception(detail)
          # If we rescued an error, then we return 1 as the exit code
          1
        ensure
          Puppet[:vardir] = vardir
          Puppet[:confdir] = confdir
          Puppet[:certname] = certname
          Puppet::SSL::Host.reset
        end
      end
    end

    if ! returns or returns.compact.empty?
      exit(1)
    elsif options[:detailed_exitcodes]
      # Bitwise OR the return codes together, puppet style
      exit(returns.compact.reduce(:|))
    elsif returns.include? 1
      exit(1)
    else
      exit(0)
    end
  end

  def setup_host
    @host = Puppet::SSL::Host.new
    waitforcert = options[:waitforcert] || (Puppet[:onetime] ? 0 : Puppet[:waitforcert])
    @host.wait_for_cert(waitforcert)
  end

  def setup
    setup_logs

    args[:Server] = Puppet[:server]
    if options[:centrallogs]
      logdest = args[:Server]

      logdest += ":" + args[:Port] if args.include?(:Port)
      Puppet::Util::Log.newdestination(logdest)
    end

    Puppet.settings.use :main, :agent, :device, :ssl

    # We need to specify a ca location for all of the SSL-related
    # indirected classes to work; in fingerprint mode we just need
    # access to the local files and we don't need a ca.
    Puppet::SSL::Host.ca_location = :remote

    Puppet::Transaction::Report.indirection.terminus_class = :rest

    if Puppet[:catalog_cache_terminus]
      Puppet::Resource::Catalog.indirection.cache_class = Puppet[:catalog_cache_terminus].intern
    end
  end
end

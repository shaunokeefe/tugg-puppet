define tugg (
  $mysqldb_password,
  $user_password,
  $mysql_server_root_password,
  $mysqldb_name = 'django',
  $mysqldb_username = 'tugg',
  $user_name= 'tugg_user'
){
    Exec { path => ["/usr/bin/", "/usr/sbin", "/bin/", "/sbin/"]}
    file { "/opt/tugg":
        ensure => "directory",
        owner  => $user_name,
    }

    # Logging directory for django
    file { "/var/log/tugg/":
        ensure => "directory",
        owner  => $user_name,
        group  => $user_name,
    }

    user { $user_name:
        ensure => 'present',
        password => $user_password,
        comment => 'TUGG User',
    }
    
    file { "/etc/tugg/":
        ensure => "directory",
        owner  => $user_name,
    }
    
    file { "$name-my.cnf":
	path => "/etc/tugg/my.cnf",
        ensure => "file",
        owner  => $user_name,
        content => template("tugg/my.cnf.erb"),
        before => Service['supervisor'],
    }

    package { 'git':
      ensure => installed,
    } 
    
    vcsrepo { "/opt/tugg/gigs":
        ensure  => present,
        provider => git,
        source =>"git://github.com/shaunokeefe/gigs.git",
        revision => 'master',
	owner => $user_name,
	before => Exec["bootstrap"],
	require => User[$user_name],
        }

    # MySQL server (replace password)
    class { 'mysql::server':
        config_hash => {
          'root_password' => $mysql_server_root_password,
        },
      }

    # Python bindings for mysql
    class { 'mysql::bindings::python': }

    # MySQL database for django
    mysql::db { $mysqldb_name:
      user     => $mysqldb_username,
      password => $mysqldb_password,
      grant    => ['all'],
      require => [Class['mysql::server'], Class['mysql::config']],
    }

    # Add SOLR server and tomcat6
    class { 'solr': 
      log_dir => '/var/log/solr',
      log_file => '/var/log/solr/solr.log',
    }

    # Bootstrap buildout for the main tugg deployment
    exec { "bootstrap":
        command => "python2.7 /opt/tugg/gigs/bootstrap.py -v 1.7.0 -c /opt/tugg/gigs/production.cfg",
        require => [Vcsrepo["/opt/tugg/gigs"]],
        user=>$user_name,
        #unless => "test -d $path/bin",
        }

    # Run buildout on TUGG checkout (gathers required packages for application)
    exec { "buildout":
        command => "/opt/tugg/gigs/bin/buildout -c /opt/tugg/gigs/production.cfg",
        require => [Exec["bootstrap"]],
        unless => "test -e /opt/tugg/gigs/bin/django",
        user=>$user_name,
        }

    # Collect static media for the TUGG project
    exec{"static-media":
        command => "/opt/tugg/gigs/bin/django collectstatic --noinput",
        require => [Exec["buildout"], Vcsrepo["/opt/tugg/gigs"], User[$user_name], Class["mysql::bindings::python"]],
        creates => "/opt/tugg/gigs/gigs/static",
        user => $user_name,
    }
    
    # Setup Supervisor, used to run gunicorn and the main app
   
    package { 'supervisor':
      ensure => installed,
    } 
    $supervisor_config = '/etc/supervisor/conf.d/tugg.conf'
    file {$supervisor_config :
        ensure => file,
        recurse=>true,
        require => Package['supervisor'],
        content => template("tugg/tugg-supervisor.cfg.erb"),
        mode => 744
    }
    service { "supervisor":
        ensure => running,
        enable =>true,
        start => "/etc/init.d/supervisor start",
        restart => "/etc/init.d/supervisor restart",
        stop => "/etc/init.d/supervisor stop",
        status => "/etc/init.d/supervisor status",
        hasstatus =>true,
        hasrestart =>true,
        require =>  [Exec['buildout'], Package['supervisor'], File[$supervisor_config]]
        }
   
    # Nginx reverse proxy to serve up our media and point to gunicorn
    # which is running our main TUGG app 
    package { 'nginx':
      ensure => installed,
    } 
    $nginx_config = '/etc/nginx/sites-enabled/default'
    file {$nginx_config :
        ensure => file,
        recurse=>true,
        content => template("tugg/nginx.cfg"),
        require => Package['nginx'],
        mode => 744
    }
    service { "nginx":
        ensure => running,
        enable =>true,
        start => "/etc/init.d/nginx  start",
        restart => "/etc/init.d/nginx restart",
        stop => "/etc/init.d/nginx stop",
        hasstatus =>true,
        hasrestart =>true,
        require =>  [Exec['buildout'], 
		Package['nginx'], File[$nginx_config], Exec['static-media']]
        }

    cron { "searchupdate":
	command => "/opt/tugg/gigs/bin/django rebuild_index",
	user    => root,
	hour    => 1,
	require =>  [Exec['buildout'],Class["mysql::bindings::python"]],
   }
}

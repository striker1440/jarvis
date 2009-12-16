# This startup.pl is run via PerlRequire in the http configuration, e.g.
#
# PerlRequire /opt/jarvis/etc/startup.pl
#
# This is run once only, for each mod_perl server process started for this
# Jarvis agent.
#

# This gives us transparant database connection pooling.  "Disconnected"
# connections are put back into the pool.
use Apache::DBI;

# This enables us to find Jarvis::Agent.
use lib qw(/opt/jarvis/lib);

1;
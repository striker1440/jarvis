###############################################################################
#
# Description: Jarvis plugin to provide a list of details about a specific 
#              application or dataset, depending on the level provided.
#
# Licence:
#       This file is part of the Jarvis Tracker application.
#
#       Jarvis is free software: you can redistribute it and/or modify
#       it under the terms of the GNU General Public License as published by
#       the Free Software Foundation, either version 3 of the License, or
#       (at your option) any later version.
#
#       Jarvis is distributed in the hope that it will be useful,
#       but WITHOUT ANY WARRANTY; without even the implied warranty of
#       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#       GNU General Public License for more details.
#
#       You should have received a copy of the GNU General Public License
#       along with Jarvis.  If not, see <http://www.gnu.org/licenses/>.
#
#       This software is Copyright 2008 by Jamie Love.
###############################################################################

use strict;
use warnings;

package JarvisTrackerSource;

use JSON::PP;
use Jarvis::DB;

# TODO This is not really safe in terms of directory path creation
sub JarvisTrackerSource::do {
    my ($jconfig, $restArgs) = @_;

    my $configFilename = $jconfig->{'etc_dir'} . "/" . $restArgs->[0] . ".xml";
    my $config = XML::Smart->new ($configFilename) || die "Cannot read '$configFilename': $!.";
    my $datasetDirectory = $config->{jarvis}{app}{dataset_dir}->content;

    my $section = $restArgs->[1];
    my $filename = $datasetDirectory;
    splice(@{$restArgs}, 0, 2);
    map { $filename .= "/" . $_; } @{$restArgs};
    $filename .= ".xml";
    my $dsxml = XML::Smart->new ($filename) || die "Cannot read '$filename': $!\n";
    return $dsxml->{dataset}->{$section}->content;
}


1;



###############################################################################
# Description:
#       Jarvis plugin to provide a list of details about a specific application or
#       dataset, depending on the level provided.
#
#       The 'node' - i.e. place to get in the tree is given by the 'node' URL argument
#       - a RESTful approach would have been nicer, but as we're currently using EXT
#       and the default tree loader works with this 'node' argument.
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

package JarvisTrackerList;

use JSON::PP;
use Jarvis::DB;

sub JarvisTrackerList::do {
    my ($jconfig, $restArgs) = @_;

    my @list;
    my $id = $jconfig->{'cgi'}->param('node');

    die "Please provide parameter 'node'" if !$id;

    my @parts = split /\//, $id;

    # Check that each part is safe. We can't have the user
    # passing in paths that could let them access files outside
    # the application directories.
    map {
        die "ERROR in node provided. Node must be made up of characters: A-Z, a-z, 0-9, _, - and space only." if ! /^[-A-Za-z0-9_ ]*$/;
    } @parts;

    #
    # For the root node, return the list of applications from the Jarvis etc directory.
    # Only look at files ending in .xml
    if (!$id || $id eq 'root') {
        opendir (APPS, $jconfig->{'etc_dir'} );
        my @files = grep (/\.xml$/, readdir (APPS));
        closedir (APPS);
        map { 
            $_ =~ s/\.xml$//;
            push(@list, { id => $_, text => $_ }); 
        } @files;
    } else {
        #
        # If there is only one part, it must be (or is expected to be) the application
        # name, so return a pre-defined list of types of objects under the app.
        if (@parts == 1) {
            my @areas = ("Errors", "Plugins", "Queries", "Users");
            map {
                push(@list, { id => "$id/$_", text => $_, leaf => $_ eq "Errors" ? 1 : 0 }); 
            } @areas;
        } else {
            #
            # If there are more than 2 parts, then we're looking at a specific 
            # lower level item within an item - Queries, Errors, Users or Plugins

            #
            # Queries
            #
            if ($parts[1] eq "Queries") {
                my $xmlFilename = $jconfig->{'etc_dir'} . "/" . $parts[0] . ".xml";
                my $xml = XML::Smart->new ($xmlFilename) || die "Cannot read configuration for $parts[0].xml: $!.";
                my $datasetDirectory = $xml->{jarvis}{app}{dataset_dir}->content;

                if (@parts > 2) {
                    splice(@parts, 0, 2);
                    map {$datasetDirectory .= "/" . $_} @parts; # all parts have been previously checked for safety - no '..' or other unsafe characters are included.
                }

                opendir (QUERIES, $datasetDirectory) || die "Cannot read queries for '$id'. $!.";
                my @files = grep (!/^\./, readdir (QUERIES));
                closedir (QUERIES);
                map { 
                    if ($_ =~ /\.xml$/) {
                        $_ =~ s/\.xml$//;
                        push(@list, { id => "$id/$_", text => $_, leaf => 1 }); 
                    } elsif (-d $datasetDirectory . "/" . $_) {
                        opendir (QUERIES, $datasetDirectory . "/" . $_);
                        my @testq = grep (/\.xml$/, readdir(QUERIES));
                        closedir (QUERIES);
                        if (@testq > 0) {
                            push(@list, { id => "$id/$_", text => $_ }); 
                        }
                    }
                } @files;
            #
            # Users
            #
            } elsif ($parts[1] eq "Users") {
                my $dbh = &Jarvis::DB::handle ($jconfig);
                my $sql = "SELECT DISTINCT username FROM request WHERE app_name = ?";
                my $sth = $dbh->prepare ($sql) || die "Couldn't prepare statement for listing users: " . $dbh->errstr;
                my $stm = {};
                $stm->{sth} = $sth;
                $stm->{ttype} = 'JarvisTrackerList-users';
                my $params = [ $parts[0] ];
                &Jarvis::Dataset::statement_execute ($jconfig, $stm, $params);
                $stm->{'error'} && die "Unable to execute statement for listing users: " . $dbh->errstr;

                my $users = $sth->fetchall_arrayref({});
                map {
                    my $u = $_->{username};
                    push(@list, { id => "$id/$u", text => $u, leaf => 1 }); 
                } @{$users};
            #
            # Plugins and execs
            #
            } elsif ($parts[1] eq "Plugins") {
                my $xmlFilename = $jconfig->{'etc_dir'} . "/" . $parts[0] . ".xml";
                my $xml = XML::Smart->new ($xmlFilename) || die "Cannot read configuration from $parts[0].xml: $!.";

                my @plugins = $xml->{jarvis}{app}{plugin}('@');
                map {
                    push(@list, { id => "$id/$_->{dataset}->content", text => $_->{dataset}->content, leaf => 1 }); 
                } @plugins;

                my @execs = $xml->{jarvis}{app}{exec}('@');
                map {
                    push(@list, { id => "$id/$_->{dataset}->content", text => $_->{dataset}->content, leaf => 1 }); 
                } @execs;

            }
        }
    }

    my @sorted = sort { lc($a->{text}) cmp lc($b->{text}) } @list;

    my $json = JSON::PP->new->pretty(1);
    return $json->encode ( \@sorted );
}


1;


###############################################################################
# Description:  Dataset access functions for SSAS DataPump access.
#
#               A SDP dataset is defined by a <dataset>.xml file which contains
#               a single MDX query.
#
# Licence:
#       This file is part of the Jarvis WebApp/Database gateway utility.
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
#       This software is Copyright 2008 by Jonathan Couper-Smartt.
###############################################################################
#
use strict;
use warnings;

use XML::Smart;

package Jarvis::Dataset::MongoDB;

use boolean;
use BSON::Types ':all'; 

use Jarvis::Text;
use Jarvis::Error;
use Jarvis::DB;
use Jarvis::Hook;

use sort 'stable';      # Don't mix up records when server-side sorting

XSLoader::load ('Jarvis::JSON::Utils');

################################################################################
# Reads a JSON object and finds/checks the ~varname!flag~ variable components.
#
# Params:
#       $jconfig - Jarvis::Config object
#       $object_json - JSON content pulled out of dataset.
#       $vars - ARRAY reference of vars to pull out.
#
# Returns:
#       $object parsed from JSON.  Variables not yet substituted.
################################################################################
sub parse_object {
    my ($jconfig, $object_json, $vars) = @_;

    # Convert to perl object -- extracting any variable references.
    # We don't trap parsing errors, just let them fire.
    my $object = Jarvis::JSON::Utils::decode ($object_json, $vars);

    # Check the vars.
    foreach my $var (@$vars) {

        # Here's the arg name.
        my $name = $var->{name};

        # Strip all the !flag from the tail.
        my %flags = ();
        while ($name =~ m/^(.*)(\![a-zA-Z\_]+)$/) {
            $name = $1;
            my $flag = lc ($2);
            $flag =~ s/[^a-zA-Z\_]//g;
            $flags {$flag} = 1;
        }

        # This is the trimmed name.
        my @names = split ('\|', $name);
        foreach my $orname (@names) {
            if ($orname !~ m/^[\.a-zA-Z0-9\_\-\:]+$/) {
                die "Unsupported characters in JSON substitution variable '$name'."
            }
        }

        $var->{flags} = \%flags;
        $var->{names} = \@names;

        # This is printed later when we expand vars.  Let's not duplicate the debug.
        #&Jarvis::Error::debug ($jconfig, "Variable: %s [%s].", join ('|', @names), join (",", sort (keys (%flags))));
    }

    return $object;
}

################################################################################
# Make a deep copy of the object and remove any \undef and empty attributes.
#
#   Remove any ARRAY elements that == \undef
#   Remove any HASH entries with value == \undef
#   Remove any empty ARRAY elements
#   Remove any empty HASH objects
#
# TODO: Rewrite this as an XS module for improved speed.
#
# TODO: Check that this really does create new copies of variables in the 
#       template (when called more than once per template).
#
# Note that a completely empty TOP-LEVEL object will return as undef not \undef.
#
# Params:
#       $jconfig - Jarvis::Config object
#       $var - The object which we will copy.
#
# Returns:
#       $copy
################################################################################
sub copy_and_elide {
    my ($jconfig, $var) = @_;

    # Depth-first copy all the elements.
    # Remove all the \undef elements from the array.
    # Then return an array iff there's anything left after elision.
    if (ref ($var) eq 'ARRAY') {
        my $ret = [];
        my $i = 0;
        foreach my $element (@$var) {
            my $new = &copy_and_elide ($jconfig, $element);
            if ((ref ($new) ne 'SCALAR') || (defined $$new)) {
                &Jarvis::Error::debug ($jconfig, "Keeping array element '%d' (type '%s').", $i, ref ($new));
                push (@$ret, $new);

            } else {
                &Jarvis::Error::debug ($jconfig, "Discarding array element '%d'.", $i);
            }
            $i++;
        }
        if (scalar (@$ret)) {
            &Jarvis::Error::debug ($jconfig, "Returning array with %d elements.", scalar (@$ret));
            return $ret;

        } else {
            &Jarvis::Error::debug ($jconfig, "Discarding empty array.");
            return \undef;
        }

    # Depth-first copy all the elements.
    # Remove all the \undef elements from the array.
    # Then return an array iff there's anything left after elision.
    } elsif (ref ($var) eq 'HASH') {
        my $ret = {};
        foreach my $key (keys %$var) {
            my $element = $var->{$key};
            my $new = &copy_and_elide ($jconfig, $element);
            if ((ref ($new) ne 'SCALAR') || (defined $$new)) {
                &Jarvis::Error::debug ($jconfig, "Keeping key '%s' (type '%s').", $key, ref ($new));
                $ret->{$key} = $new;

            } else {
                &Jarvis::Error::debug ($jconfig, "Discarding key '%s'.", $key);
            }
        }
        if (scalar (keys (%$ret))) {
            &Jarvis::Error::debug ($jconfig, "Returning hash with %d keys.", scalar (keys (%$ret)));
            return $ret;

        } else {
            &Jarvis::Error::debug ($jconfig, "Discarding empty hash.");
            return \undef;
        }

    # Scalars we just pass up so our parents can elide us if they so desire.
    #} elsif (ref ($var) eq '') {
    #    return scalar ($var);

    # Anything else we just pass up.
    } else {
        return scalar $var;
    }
}

################################################################################
# Make a deep copy of the object and convert all MongoDB classes to Perl.
#
# Params:
#       $jconfig - Jarvis::Config object
#       $var - The object which we will copy and convert.
#
# Returns:
#       $copy
################################################################################
sub mongo_to_perl {
    my ($jconfig, $var) = @_;

    if (ref ($var) eq 'ARRAY') {
        my $ret = [];
        foreach my $element (@$var) {
            push (@$ret, &mongo_to_perl ($jconfig, $element));
        }
        return $ret;

    } elsif (ref ($var) eq 'HASH') {
        my $ret = {};
        foreach my $key (keys %$var) {
            $ret->{$key} = &mongo_to_perl ($jconfig, $var->{$key});
        }
        return $ret;

    } elsif (ref ($var) eq 'boolean') {
        return $var ? \1 : \0;

    } elsif (ref ($var) eq 'MongoDB::OID') {

        return $var->value;
    } elsif (ref ($var) eq 'BSON::Decimal128') {
        return $var->value;

    } elsif (ref ($var) eq 'DateTime' ) {
        return $var->epoch ();

    } else {
        # For any non sclar types that have a blessed type stop and warn the user to implement them.
        if (ref ($var)) {
            die ("Unsupported Blessed Type: " . ref ($var));
        }
    }


    # Scalars we just pass up so our parents can elide us if they so desire.
    #} elsif (ref ($var) eq '') {
    #    return scalar ($var);

    # Anything else we just pass up.
    return $var;
}

################################################################################
# Expand the previously parsed variables in the object to actual values.
#
#   a) Look up the variable name(s) in our $values HASH
#   b) Perform any !flag type coversion or other mapping.
#
# Note that any variable that isn't found in our names hash will be converted 
# \undef in the expansion process (and then removed in the COPY) process.
#
# We invoke copy_and_elide on the result, see the processing above. 
#
# Params:
#       $jconfig - Jarvis::Config object
#       $object - The object which we will substitute.
#       $vars - ARRAY reference of vars to pull out.
#       $values - HASH reference of values to expand.
#
# Returns:
#       undef
################################################################################
sub expand_vars {
    my ($jconfig, $object, $vars, $values) = @_;

    foreach my $var (@$vars) {
        &Jarvis::Error::debug ($jconfig, "Variable: %s [%s].", join ('|', @{ $var->{names} }), join (",", sort (keys (%{ $var->{flags} }))));

        # Clear the variable to remove any values left over from last time.
        my $vref = $var->{vref};
        my $matched = 0;
        foreach my $name (@{ $var->{names} }) {
            my $value = $values->{$name};
            if (defined $value) {
                &Jarvis::Error::debug ($jconfig, "Matched Name '%s' -> %s.", $name, (ref $value) || $value);
                $$vref = $value;
                $matched = 1;
                last;

            } else {
                &Jarvis::Error::debug ($jconfig, "No Value for '%s'.", $name);
            }
        }

        # Mark it with a "REMOVE ME" flag.
        # This will force a COPY even if not required.
        if (! $matched) {
            &Jarvis::Error::debug ($jconfig, "No name matched.  Set = \\undef for later removal.");
            $$vref = \undef;
        }

        #######################################################################
        # DOCUMENTED DOCUMENTED DOCUMENTED DOCUMENTED DOCUMENTED
        # -- These features are officially documented, remember to
        # -- update the documentation if you change/extend then.
        #######################################################################
        # Flag processing now.
        #
        # Note that flags are not processed in the order in which they are 
        # present in the variable specifier.
        #
        my $flags = $var->{flags};

        # BOOLEAN is only used to replace 0/1.  An "undef" is not translated.
        if ($flags->{boolean} && $matched && defined ($$vref)) {
            &Jarvis::Error::debug ($jconfig, "Applying BOOLEAN replacement.");
            $$vref = $$vref ? boolean::true : boolean::false;
        }

        # MongoDB::OID is used to replace string GUIID Object IDs. An "undef" is not translated.
        if ($flags->{oid} && $matched && defined ($$vref)) {
            &Jarvis::Error::debug ($jconfig, "Applying OID replacement.");
            $$vref = MongoDB::OID->new (value => $$vref);
        }

        # Perl DateTime is used to replace epoch date values. An "undef" is not translated.
        if ($flags->{date} && $matched && defined ($$vref)) {
            &Jarvis::Error::debug ($jconfig, "Applying Date replacement.");
            $$vref = DateTime->from_epoch (epoch => $$vref);
        }

        # BSON::Decimal128 is used to replace decimal values. An "undef" is not translated.
        if ($flags->{decimal} && $matched && defined ($$vref)) {
            &Jarvis::Error::debug ($jconfig, "Applying Decimal 128 replacement.");
            $$vref = BSON::Decimal128->new (value => $$vref);
        }

        # BSON::Regex is used to replace case insensitive regex match values. An "undef" is not translated.
        if ($flags->{insensitive_regex} && $matched && defined ($$vref)) {
            &Jarvis::Error::debug ($jconfig, "Applying Case Insensitive Regex replacement.");
            
            # Construct and compile the regex with the `i` insensitive matching flag.
            my $regex = bson_regex ($$vref, 'i');
            my $compiled_regex = $regex->try_compile or die ("Failed to compiled regular expression for BSON::Regex type conversion.");
            $$vref = $compiled_regex;
        }
    }

    &Jarvis::Error::debug_var ($jconfig, $object);
    my $copy = &copy_and_elide ($jconfig, $object);
    &Jarvis::Error::debug_var ($jconfig, $copy);

    # Never return \undef, that's not nice to do.
    if ((ref ($copy) eq 'SCALAR') && (! defined $$copy)) {
        return undef;

    } else {
        return $copy;
    }
}

################################################################################
# Loads the data for the current dataset(s), and puts it into our return data
# array so that it can be presented to the client in JSON or XML or whatever.
#
# This function only processes a single dataset.  The parent method may invoke
# us multiple times for a single request, and combine into a single return 
# object.
#
# Params:
#       $jconfig - Jarvis::Config object
#           READ
#               cgi                 Contains data values for {{param}} in MDX
#               username            Used for {{username}} in MDX
#               group_list          Used for {{group_list}} in MDX
#               format              Either "json" or "xml" or "csv".
#
#       $subset_name - Name of single dataset we are fetching from.
#       $dsxml - Dataset's XML configuration object.
#       $dbh - Database handle of the correct type to match the dataset.
#       $safe_params_href - All our safe parameters.
#
# Returns:
#       $rows_aref - Array of tuple data returned.
#       $column_names_aref - Array of tuple column names, if available.
################################################################################
sub fetch_inner {
    my ($jconfig, $subset_name, $dsxml, $dbh, $safe_params_href) = @_;

    # Start with the collection.  This is at the top level of the datasets.
    # TODO: Maybe allow different operations to override the collection name?
    $dsxml->{dataset}{collection} or die "Dataset '$subset_name' (type 'mongo') has no 'collection' defined.\n";
    my $collection_name = $dsxml->{dataset}{collection}->content;

    # Check that both find and aggregate are not defined at the same time.
    if ($dsxml->{dataset}{find} && $dsxml->{dataset}{aggregate}) {
        die "Dataset '$subset_name' (type 'mongo') has both 'find' and 'aggregate' present.\n";
    }

    # This is the collection handle.
    my $collection = $dbh->ns ($collection_name);
    my $cursor     = undef;

    # We must also have either a <find> or <aggregate> block present in the dataset.  
    # Extract the filter and options from each type as required.
    if ($dsxml->{dataset}{find}) {

        # Do we have a filter?  It can be undef, it's purely optional.
        my $filter  = undef;
        my $options = undef;

        # Parse the filter from JSON and perform variable substitution.
        if ($dsxml->{dataset}{find}{filter}) {
            my $filter_vars     = [];
            my $object_json     = $dsxml->{dataset}{find}{filter}->content;
            my $filter_template = &parse_object ($jconfig, $object_json, $filter_vars);
            $filter             = &expand_vars ($jconfig, $filter_template, $filter_vars, $safe_params_href);
        }

        # Parse the options from JSON and perform variable substitution.
        if ($dsxml->{dataset}{find}{options}) {
            my $options_vars     = [];
            my $object_json      = $dsxml->{dataset}{find}{options}->content;
            my $options_template = &parse_object ($jconfig, $object_json, $options_vars);
            $options             = &expand_vars ($jconfig, $options_template, $options_vars, $safe_params_href);
        }

        # Execute our Mongo find.
        $cursor = $collection->find ($filter, $options)


    } elsif ($dsxml->{dataset}{aggregate}) {

        # Do we have a pipeline? It must be defined.
        my @pipeline = undef;
        my $options  = undef;

        # Parse the pipeline from JSON and perform variable substitution.
        if ($dsxml->{dataset}{aggregate}{pipeline}) {
            my $pipeline_vars     = [];
            my $object_json       = $dsxml->{dataset}{aggregate}{pipeline}->content;
            my $pipeline_template = &parse_object ($jconfig, $object_json, $pipeline_vars);
            @pipeline = &expand_vars ($jconfig, $pipeline_template, $pipeline_vars, $safe_params_href);
        }
        
        # Parse the options from JSON and perform variable substitution.
        if ($dsxml->{dataset}{aggregate}{options}) {
            my $options_vars     = [];
            my $object_json      = $dsxml->{dataset}{aggregate}{options}->content;
            my $options_template = &parse_object ($jconfig, $object_json, $options_vars);
            $options             = &expand_vars ($jconfig, $options_template, $options_vars, $safe_params_href);
        }

        @pipeline or die "Dataset '$subset_name' (type 'mongo' - 'aggregate') does not have a pipeline present.\n";

        # Execute our Mongo aggregate.
        $cursor = $collection->aggregate (@pipeline, $options);

    } else {
        # Either 'find' or 'aggregatea' MUST be present, EVEN IF THEY ARE EMPTY.
        die "Dataset '$subset_name' (type 'mongo') has no 'find' or 'aggregate' present.\n";
    }

    
    # Process the rows returned from each our method cursors.
    my $rows_aref = [];
    while (my $document = $cursor->next ) {
        &Jarvis::Error::debug_var ($jconfig, $document);
        push (@$rows_aref, &mongo_to_perl ($jconfig, $document));
    }

    return ($rows_aref); 
}

1;

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

package Jarvis::Agent::MongoDB;

use parent qw(Jarvis::Agent);

use boolean;
use Data::Dumper;
use BSON::Types ':all'; 

use Jarvis::Text;
use Jarvis::Error;
use Jarvis::DB;
use Jarvis::Hook;

use sort 'stable';      # Don't mix up records when server-side sorting

use Jarvis::JSON::Utils;

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
                # &Jarvis::Error::dump ($jconfig, "Keeping array element '%d' (type '%s').", $i, ref ($new));
                push (@$ret, $new);

            } else {
                # &Jarvis::Error::dump ($jconfig, "Discarding array element '%d'.", $i);
            }
            $i++;
        }
        if (scalar (@$ret)) {
            # &Jarvis::Error::dump ($jconfig, "Returning array with %d elements.", scalar (@$ret));
            return $ret;

        } else {
            # &Jarvis::Error::dump ($jconfig, "Discarding empty array.");
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
                # &Jarvis::Error::dump ($jconfig, "Keeping key '%s' (type '%s').", $key, ref ($new));
                $ret->{$key} = $new;

            } else {
                # &Jarvis::Error::dump ($jconfig, "Discarding key '%s'.", $key);
            }
        }
        if (scalar (keys (%$ret))) {
            # &Jarvis::Error::dump ($jconfig, "Returning hash with %d keys.", scalar (keys (%$ret)));
            return $ret;

        } else {
            # &Jarvis::Error::dump ($jconfig, "Discarding empty hash.");
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
        &Jarvis::Error::debug_var ($jconfig, $values);

        # Clear the variable to remove any values left over from last time.
        my $vref = $var->{vref};
        my $matched = 0;
        foreach my $name (@{ $var->{names} }) {
            if (exists $values->{$name}) {
                my $value = $values->{$name};
                &Jarvis::Error::debug ($jconfig, "Matched Name '%s' -> %s.", $name, (ref $value) || $value);
                $$vref = $value;
                $matched = 1;
                last;

            } else {
                &Jarvis::Error::debug ($jconfig, "No Value for '%s'.", $name);
            }
        }

        # Now is a special variable less type that will insert the current system time into the query.
        # Must like how NOW () exists within SQL.
        # Note that this is a stopgap until Mongo 4.2 is releases which will support $$NOW to insert the current time without NodeJS nonsense.
        if ($var->{flags}{now}) {
            &Jarvis::Error::debug ($jconfig, "Applying Now Date Repleacement.");
            $$vref = DateTime->now ();
            $matched = 1;
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

        # "null" means use undef even if not matched.
        if ($flags->{null} && ! $matched) {
            $matched = 1;
            $$vref = undef;
        }
    }

    &Jarvis::Error::debug ($jconfig, "Before copy/elide:");
    &Jarvis::Error::debug_var ($jconfig, $object);

    my $copy = &copy_and_elide ($jconfig, $object);

    &Jarvis::Error::debug ($jconfig, "After copy/elide:");
    &Jarvis::Error::debug_var ($jconfig, $copy);

    # Never return \undef, that's not nice to do.
    if ((ref ($copy) eq 'SCALAR') && (! defined $$copy)) {
        return undef;

    } else {
        return $copy;
    }
}

################################################################################
# AGENT METHOD OVERRIDE
################################################################################

################################################################################
# Loads the data for the current dataset(s), and puts it into our return data
# array so that it can be presented to the client in JSON or XML or whatever.
#
# This function only processes a single dataset.  The parent method may invoke
# us multiple times for a single request, and combine into a single return 
# object.
#
# Params:
#       $class - Agent classname.
#       $jconfig - Jarvis::Config object
#           READ
#               cgi                 Contains data values for {{param}} in MDX
#               username            Used for {{username}} in MDX
#               group_list          Used for {{group_list}} in MDX
#               format              Either "json" or "xml" or "csv".
#
#       $dataset_name - Name of single dataset we are fetching from.
#       $dsxml - Dataset's XML configuration object.
#       $dbh - Database handle of the correct type to match the dataset.
#       $safe_params_href - All our safe parameters.
#
# Returns:
#       $rows_aref - Array of tuple data returned.
#       $column_names_aref - Array of tuple column names, if available.
################################################################################
sub fetch_inner {
    my ($class, $jconfig, $dataset_name, $dsxml, $dbh, $safe_params_href) = @_;

    # Start with the collection.  This is at the top level of the datasets.
    # TODO: Maybe allow different operations to override the collection name?
    $dsxml->{dataset}{collection} or die "Dataset '$dataset_name' (type 'mongo') has no 'collection' defined.\n";
    my $collection_name = $dsxml->{dataset}{collection}->content;

    # Check that both find and aggregate are not defined at the same time.
    if ($dsxml->{dataset}{find} && $dsxml->{dataset}{aggregate}) {
        die "Dataset '$dataset_name' (type 'mongo') has both 'find' and 'aggregate' present.\n";
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

            &Jarvis::Error::dump ($jconfig, "Parsing filter...");
            &Jarvis::Error::dump ($jconfig, $object_json);
            my $filter_template = &parse_object ($jconfig, $object_json, $filter_vars);
            $filter             = &expand_vars ($jconfig, $filter_template, $filter_vars, $safe_params_href);
        }

        # Parse the options from JSON and perform variable substitution.
        if ($dsxml->{dataset}{find}{options}) {
            my $options_vars     = [];
            my $object_json      = $dsxml->{dataset}{find}{options}->content;

            &Jarvis::Error::dump ($jconfig, "Parsing options...");
            &Jarvis::Error::dump ($jconfig, $object_json);
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

            &Jarvis::Error::dump ($jconfig, "Parsing pipeline...");
            &Jarvis::Error::dump ($jconfig, $object_json);
            my $pipeline_template = &parse_object ($jconfig, $object_json, $pipeline_vars);
            @pipeline = &expand_vars ($jconfig, $pipeline_template, $pipeline_vars, $safe_params_href);
        }
        
        # Parse the options from JSON and perform variable substitution.
        if ($dsxml->{dataset}{aggregate}{options}) {
            my $options_vars     = [];
            my $object_json      = $dsxml->{dataset}{aggregate}{options}->content;

            &Jarvis::Error::dump ($jconfig, "Parsing options...");
            &Jarvis::Error::dump ($jconfig, $object_json);
            my $options_template = &parse_object ($jconfig, $object_json, $options_vars);
            $options             = &expand_vars ($jconfig, $options_template, $options_vars, $safe_params_href);
        }

        @pipeline or die "Dataset '$dataset_name' (type 'mongo' - 'aggregate') does not have a pipeline present.\n";

        # Execute our Mongo aggregate.
        $cursor = $collection->aggregate (@pipeline, $options);

    } else {
        # Either 'find' or 'aggregatea' MUST be present, EVEN IF THEY ARE EMPTY.
        die "Dataset '$dataset_name' (type 'mongo') has no 'find' or 'aggregate' present.\n";
    }

    
    # Process the rows returned from each our method cursors.
    my $rows_aref = [];
    while (my $document = $cursor->next ) {
        push (@$rows_aref, &mongo_to_perl ($jconfig, $document));
    }

    return ($rows_aref); 
}

################################################################################
# Performs an update to the specified table underlying the named dataset.
#
# Params:
#       $class - Agent classname.
#       $jconfig - Jarvis::Config object
#           READ
#               cgi                 Submitted content and content-type.
#               username            Used for {{username}} in SQL
#               group_list          Used for {{group_list}} in SQL
#               format              Either "json" or "xml" (not "csv").
#
#       $dataset_name - Name of single dataset we are storing to.
#       $dsxml - Dataset XML object.
#       $dbh - Database handle of the correct type to match the dataset.
#       $stms - Hash of pre-prepared statements by row type.
#       $row_ttype - Transaction type for this row.
#       $safe_params - All our safe parameters.
#       $fields_href - The raw fields.  We echo those for some DB types.
#
# Returns:
#       $row_result - HASH REF containing {
#           success => 0/1
#           modified => num-modified,
#           message => Error message if not success,
#           returning => ARRAY of returned rows
#       }
#       die on hard error.
################################################################################
#
sub store_inner {
    my ($class, $jconfig, $dataset_name, $dsxml, $dbh, $stms, $row_ttype, $safe_params, $fields_href) = @_;

    # Start with the collection.  This is at the top level of the datasets.
    # TODO: Maybe allow different operations to override the collection name?
    $dsxml->{dataset}{collection} or die "Dataset '$dataset_name' (type 'mongo') has no 'collection' defined.\n";
    my $collection_name = $dsxml->{dataset}{collection}->content;

    # Get the statement type for this ttype if we don't have it.  This raises debug.
    if (! $stms->{$row_ttype}) {
        ($dsxml->{dataset}{$row_ttype}) or die "Dataset '$dataset_name' (type 'mongo') has no '$row_ttype' defined.\n";        

        # Delete has only a document.
        # TODO: Add <options> support?
        if ($row_ttype eq 'delete') {
            ($dsxml->{dataset}{$row_ttype}{filter}) or die "Dataset '$dataset_name' (type 'mongo') has no '$row_ttype.filter' defined.\n";        
            my $object_json = $dsxml->{dataset}{$row_ttype}{filter}->content;
            my $filter_vars = [];

            &Jarvis::Error::dump ($jconfig, "Parsing $row_ttype.filter...");
            &Jarvis::Error::dump ($jconfig, $object_json);
            my $filter_template = &parse_object ($jconfig, $object_json, $filter_vars);

            $stms->{$row_ttype}{filter} = { vars => $filter_vars, template => $filter_template };

            # Document
            if ($dsxml->{dataset}{$row_ttype}{document}) {

                $object_json = $dsxml->{dataset}{$row_ttype}{document}->content;
                my $document_vars = [];

                &Jarvis::Error::dump ($jconfig, "Parsing $row_ttype.document...");
                &Jarvis::Error::dump ($jconfig, $object_json);
                my $document_template = &parse_object ($jconfig, $object_json, $document_vars);

                $stms->{$row_ttype}{document} = { vars => $document_vars, template => $document_template };
            }

        # Insert has only a document.
        # TODO: Add <options> support?
        } elsif ($row_ttype eq 'insert') {
            ($dsxml->{dataset}{$row_ttype}{document}) or die "Dataset '$dataset_name' (type 'mongo') has no '$row_ttype.document' defined.\n";        
            my $object_json = $dsxml->{dataset}{$row_ttype}{document}->content;
            my $document_vars = [];

            &Jarvis::Error::dump ($jconfig, "Parsing $row_ttype.document...");
            &Jarvis::Error::dump ($jconfig, $object_json);
            my $document_template = &parse_object ($jconfig, $object_json, $document_vars);

            $stms->{$row_ttype}{document} = { vars => $document_vars, template => $document_template };

        # Update requires a filter and a document.
        # TODO: Add <options> support?
        } elsif ($row_ttype eq 'update') {

            # Filter
            ($dsxml->{dataset}{$row_ttype}{filter}) or die "Dataset '$dataset_name' (type 'mongo') has no '$row_ttype.filter' defined.\n";        
            my $object_json = $dsxml->{dataset}{$row_ttype}{filter}->content;
            my $filter_vars = [];

            &Jarvis::Error::dump ($jconfig, "Parsing $row_ttype.filter...");
            &Jarvis::Error::dump ($jconfig, $object_json);
            my $filter_template = &parse_object ($jconfig, $object_json, $filter_vars);

            $stms->{$row_ttype}{filter} = { vars => $filter_vars, template => $filter_template };

            # Document
            ($dsxml->{dataset}{$row_ttype}{document}) or die "Dataset '$dataset_name' (type 'mongo') has no '$row_ttype.document' defined.\n";        
            $object_json = $dsxml->{dataset}{$row_ttype}{document}->content;
            my $document_vars = [];

            &Jarvis::Error::dump ($jconfig, "Parsing $row_ttype.document...");
            &Jarvis::Error::dump ($jconfig, $object_json);
            my $document_template = &parse_object ($jconfig, $object_json, $document_vars);

            $stms->{$row_ttype}{document} = { vars => $document_vars, template => $document_template };

        } else {
            die "Unsupported 'store' row type '$row_ttype'.";
        }
    }

    # Determine our argument values.
    my $stm = $stms->{$row_ttype};

    my $objects = {};
    foreach my $key (sort (keys (%$stm))) {
        my $template = $stm->{$key}{template};
        my $vars = $stm->{$key}{vars};    
        $objects->{$key} = &expand_vars ($jconfig, $template, $vars, $safe_params);

        &Jarvis::Error::debug ($jconfig, "Resulting %s after expansion.", $key);
        &Jarvis::Error::debug_var ($jconfig, $objects->{$key});
    }

    # Execute
    my $row_result = {};
    my $num_rows = 0;

    # This is worth having.
    my $collection_handle = $dbh->ns ($collection_name);

    # Check for update or deletes that contain an update document. This is neccesary for
    # cases where deletes simply set a `deleted` flag from `false` to `true`
    #
    # We do not support any MongoDB options for update.
    if (($row_ttype eq 'update') || ($row_ttype eq 'delete' && defined $objects->{document})) {
        eval {
            my $retval = $collection_handle->update_one ($objects->{filter}, $objects->{document});

            # FIXME: Add checking for "write_errors".

            $row_result->{success} = 1;
            $row_result->{modified} = $retval->{modified_count} // 0;
            if ($retval->{upserted_id}) {
                $row_result->{returning} = [ { _id => $retval->{upserted_id}->value } ];
            }
        };
        if ($@) {
            my $message = ($@->isa ('MongoDB::Error')) ? $@->{message} : $@;
            $message =~ s| at [\.\w\d\\\/]+ line \d+\..*||s;

            $row_result->{success} = 0;
            $row_result->{modified} = 0;
            $row_result->{message} = $message;
        }

    # We do not support any MongoDB options for delete.
    } elsif ($row_ttype eq 'delete') {
        eval {
            my $retval = $collection_handle->delete_one ($objects->{filter});

            # FIXME: Add checking for "write_errors".

            $row_result->{success} = 1;
            $row_result->{modified} = $retval->{deleted_count} // 0;
        };
        if ($@) {
            my $message = ($@->isa ('MongoDB::Error')) ? $@->{message} : $@;
            $message =~ s| at [\.\w\d\\\/]+ line \d+\..*||s;

            $row_result->{success} = 0;
            $row_result->{modified} = 0;
            $row_result->{message} = $message;
        }

    # We do not support any MongoDB options for insert.
    } elsif ($row_ttype eq 'insert') {
        eval {
            my $retval = $collection_handle->insert_one ($objects->{document});

            # FIXME: Add checking for "write_errors".

            $row_result->{success} = 1;
            $row_result->{modified} = 1;
            $row_result->{returning} = [ { _id => $retval->{inserted_id}->value } ];
        };
        if ($@) {
            my $message = ($@->isa ('MongoDB::Error')) ? $@->{message} : $@;
            $message =~ s| at [\.\w\d\\\/]+ line \d+\..*||s;

            $row_result->{success} = 0;
            $row_result->{modified} = 0;
            $row_result->{message} = $message;
        }
    } else {
        die "Unsupported 'store' row type '$row_ttype'.";
    }

    # TODO: Add $row_result->{returning}!
    return $row_result;

    # On failure, we will still return valid JSON/XML to the caller, but we will indicate
    # which request failed and will send back an overall "non-success" flag.
    #
    if ($stm->{error}) {
        $row_result->{success} = 0;
        $row_result->{modified} = 0;
        $row_result->{message} = $stm->{error};

    # Suceeded.  Set per-row status, and fetch the returned results, if this
    # operation indicates that it returns values.
    #
    } else {
        # DUMMY value just to avoid undef vars.
        # All of the code below is purely an example from the DBI.
        # Needs a complete re-write for MongoDB.
        my @arg_values = (); 

        $row_result->{success} = 1;

        # Try and determine the returned values (normally the auto-increment ID)
        if ($stm->{returning}) {

            # If you flagged any variables as "!out" then we will have used
            # bind_param_inout () and copied the output vars into $stm->{returned}.
            # In this case, all the work is already done, and we just need to copy
            # everything through.
            if ($stm->{returned}) {

                my $row = {};
                foreach my $name (keys %{ $stm->{returned} }) {
                    my $value_ref = $stm->{returned}{$name};
                    $row->{$name} = $$value_ref;
                }

                $row_result->{returning} = [ $row ];
                &Jarvis::Error::debug ($jconfig, "Copied single row from bind_param_inout results.");

            # SQLite uses the last_insert_rowid() function for returning IDs.  
            # This is very special case handling.  We echo the input fields too!
            #
            } elsif ($dbh->{Driver}{Name} eq 'SQLite') {

                my $rowid = $dbh->func('last_insert_rowid');
                if ($rowid) {
                    my $returning_row = {};
                    foreach my $field (keys %$fields_href) {
                        (ref $fields_href->{$field} eq '') && ($returning_row->{$field} = $fields_href->{$field});
                    }
                    $returning_row->{id} = $rowid;
                    $row_result->{returning} = [ $returning_row ];
                    &Jarvis::Error::debug ($jconfig, "Used SQLite last_insert_rowid to get returned 'id' => '$rowid'.");

                } else {
                    &Jarvis::Error::log ($jconfig, "Used SQLite last_insert_rowid but it returned no id.");
                }

            # Otherwise: See if the query had a built-in fetch.  Under PostGreSQL (and very
            # likely also under other drivers) this will fail if there is no current
            # query.  I.e. if you have no "RETURNING" clause on your insert.
            #
            } else {
                my $returning_aref = $stm->{sth}->fetchall_arrayref({}) || undef;

                if ($returning_aref && (scalar @$returning_aref)) {
                    if ($DBI::errstr) {
                        my $error_message = $DBI::errstr;
                        $error_message =~ s/\s+$//;

                        if (&nolog ($stm, $error_message)) {
                            &Jarvis::Error::debug ($jconfig, "Failure fetching first return result set. Log disabled.");
                        } else {
                            &Jarvis::Error::log ($jconfig, "Failure fetching first return result set for '" . $stm->{ttype} . "'.  Details follow.");
                            &Jarvis::Error::log ($jconfig, $stm->{sql_with_substitutions}) if $stm->{sql_with_substitutions};
                            &Jarvis::Error::log ($jconfig, $error_message);
                            &Jarvis::Error::log ($jconfig, "Args = " . (join (",", map { (defined $_) ? "'$_'" : 'NULL' } @arg_values) || 'NONE'));
                        }

                        $stm->{sth}->finish;
                        $stm->{error} = $error_message;
                        $row_result->{success} = 0;
                        $row_result->{message} = $error_message;
                    }

                    $row_result->{returning} = $returning_aref;
                    &Jarvis::Error::debug ($jconfig, "Fetched " . (scalar @$returning_aref) . " rows for returning.");
                }

                # When using output parameters from a SQL Server stored procedure, there is a
                # difference of behavior between Linux/FreeTDS and Windows/ODBC.  Under Linux you
                # always get a result set containing the output parameters, with autogenerated
                # column names prefixed by underscore.
                #
                # Under Windows you need to explicitly do a SELECT to get this and you must
                # specify the column names.
                #
                # This leads to the case where to write a dataset that works under both Linux
                # and Windows, you need to explicitly SELECT (so that you get the data under
                # Windows, and make sure that the column name you select AS is identical to the
                # auto-generated name created by FreeTDS).
                #
                # However, under Linux that means you get two result sets.  If you pass more than
                # one <row> in your request, then the second row will fail with
                # "Attempt to initiate a new Adaptive Server operation with results pending"
                #
                # To avoid that error, here we will look to see if there are any extra result
                # sets now pending to be read.  We will silently read and discard them.
                #
                while ($row_result->{success} && $stm->{sth}{syb_more_results}) {
                    &Jarvis::Error::debug ($jconfig, "Found additional result sets.  Fetch and discard.");
                    $stm->{sth}->fetchall_arrayref ({});

                    if ($DBI::errstr) {
                        my $error_message = $DBI::errstr;
                        $error_message =~ s/\s+$//;

                        if (&nolog ($stm, $error_message)) {
                            &Jarvis::Error::debug ($jconfig, "Failure fetching additional result sets. Log disabled.");
                        } else {
                            &Jarvis::Error::log ($jconfig, "Failure fetching additional result sets for '" . $stm->{ttype} . "'.  Details follow.");
                            &Jarvis::Error::log ($jconfig, $stm->{sql_with_substitutions}) if $stm->{sql_with_substitutions};
                            &Jarvis::Error::log ($jconfig, $error_message);
                            &Jarvis::Error::log ($jconfig, "Args = " . (join (",", map { (defined $_) ? "'$_'" : 'NULL' } @arg_values) || 'NONE'));
                        }

                        $stm->{sth}->finish;
                        $stm->{error} = $error_message;
                        $row_result->{success} = 0;
                        $row_result->{message} = $error_message;
                    }
                }
            }

            # This is disappointing, but perhaps a "die" is too strong here.
            if (! $row_result->{returning}) {
                &Jarvis::Error::debug ($jconfig, "Cannot determine how to get values for 'returning' statement.");
            }
        }
    }

    return $row_result;
}

1;

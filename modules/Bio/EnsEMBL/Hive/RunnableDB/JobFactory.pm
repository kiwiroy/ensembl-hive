=pod 

=head1 NAME

Bio::EnsEMBL::Hive::RunnableDB::JobFactory

This is a RunnableDB module that implements Bio::EnsEMBL::Hive::Process interface
and is ran by Workers during the execution of eHive pipelines.
It is not generally supposed to be instantiated and used outside of this framework.

Please refer to Bio::EnsEMBL::Hive::Process documentation to understand the basics of the RunnableDB interface.

Please refer to Bio::EnsEMBL::Hive::PipeConfig::* pipeline configuration files to understand how to configure pipelines.

=head1 DESCRIPTION

This is a generic RunnableDB module for creating batches of similar jobs using dataflow mechanism
(a fan of jobs is created in one branch and the funnel in another).
Make sure you wire this buliding block properly from outside.

You can supply as parameter one of 4 sources of ids from which the batches will be generated:

    param('inputlist');  The list is explicitly given in the parameters, can be abbreviated: 'inputlist' => ['a'..'z']

    param('inputfile');  The list is contained in a file whose name is supplied as parameter: 'inputfile' => 'myfile.txt'

    param('inputquery'); The list is generated by an SQL query (against the production database by default) : 'inputquery' => 'SELECT object_id FROM object WHERE x=y'

    param('inputcmd');   The list is generated by running a system command: 'inputcmd' => 'find /tmp/big_directory -type f'

If 'sema_funnel_branch_code' is defined, it becomes the destination branch for a semaphored funnel job,
whose count is automatically set to the number of fan jobs that it will be waiting for.

=cut

package Bio::EnsEMBL::Hive::RunnableDB::JobFactory;

use strict;
use DBI;
use base ('Bio::EnsEMBL::Hive::ProcessWithParams');

=head2 fetch_input

    Description : Implements fetch_input() interface method of Bio::EnsEMBL::Hive::Process that is used to read in parameters and load data.
                  Here we have nothing to do.

=cut

sub fetch_input {
}

=head2 run

    Description : Implements run() interface method of Bio::EnsEMBL::Hive::Process that is used to perform the main bulk of the job (minus input and output).

    param('input_id'):  The template that will become the input_id of newly created jobs (Note: this is something entirely different from $self->input_id of the current JobFactory job).

    param('numeric'):   A bit flag that indicates whether the expressions with '$RangeStart', '$RangeEnd' and '$RangeCount' are expected to be numeric/evaluatable or not.

    param('step'):      The requested size of the minibatch (1 by default). The real size may be smaller.

    param('randomize'): Shuffles the ids before creating jobs - can sometimes lead to better overall performance of the pipeline. Doesn't make any sence for minibatches (step>1).

        # The following 4 parameters are mutually exclusive and define the source of ids for the jobs:

    param('inputlist');  The list is explicitly given in the parameters, can be abbreviated: 'inputlist' => ['a'..'z']

    param('inputfile');  The list is contained in a file whose name is supplied as parameter: 'inputfile' => 'myfile.txt'

    param('inputquery'); The list is generated by an SQL query (against the production database by default) : 'inputquery' => 'SELECT object_id FROM object WHERE x=y'

    param('inputcmd');   The list is generated by running a system command: 'inputcmd' => 'find /tmp/big_directory -type f'

=cut

sub run {
    my $self = shift @_;

    my $template_hash   = $self->param('input_id')      || die "'input_id' is an obligatory parameter";
    my $numeric         = $self->param('numeric')       || 0;
    my $step            = $self->param('step')          || 1;
    my $randomize       = $self->param('randomize')     || 0;

    my $inputlist       = $self->param('inputlist');
    my $inputfile       = $self->param('inputfile');
    my $inputquery      = $self->param('inputquery');
    my $inputcmd        = $self->param('inputcmd');

    my $list = $inputlist
        || ($inputfile  && $self->_make_list_from_file($inputfile))
        || ($inputquery && $self->_make_list_from_query($inputquery))
        || ($inputcmd   && $self->_make_list_from_cmd($inputcmd))
        || die "range of values should be defined by setting 'inputlist', 'inputfile' or 'inputquery'";

    if($randomize) {
        _fisher_yates_shuffle_in_place($list);
    }

    my $output_ids = $self->_split_list_into_ranges($template_hash, $numeric, $list, $step);
    $self->param('output_ids', $output_ids);
}

=head2 write_output

    Description : Implements write_output() interface method of Bio::EnsEMBL::Hive::Process that is used to deal with job's output after the execution.
                  Here we rely on the dataflow mechanism to create jobs.

    param('fan_branch_code'): defines the branch where the fan of jobs is created (2 by default).

    param('sema_funnel_branch_code'): defines the branch where the semaphored funnel for the fan is created (no default - skipped if not defined)

=cut

sub write_output {  # nothing to write out, but some dataflow to perform:
    my $self = shift @_;

    my $output_ids              = $self->param('output_ids');
    my $fan_branch_code         = $self->param('fan_branch_code') || 2;
    my $sema_funnel_branch_code = $self->param('sema_funnel_branch_code');  # if set, it is a request for a semaphored funnel

    if($sema_funnel_branch_code) {

            # first flow into the sema_funnel_branch
        my ($funnel_job_id) = @{ $self->dataflow_output_id($self->input_id, $sema_funnel_branch_code, { -semaphore_count => scalar(@$output_ids) })  };

            # then "fan out" into fan_branch, and pass the $funnel_job_id to all of them
        my $fan_job_ids = $self->dataflow_output_id($output_ids, $fan_branch_code, { -semaphored_job_id => $funnel_job_id } );

    } else {

            # simply "fan out" into fan_branch_code:
        $self->dataflow_output_id($output_ids, $fan_branch_code);
    }
}

################################### main functionality starts here ###################

=head2 _make_list_from_file
    
    Description: this is a private method that loads ids from a given file

=cut

sub _make_list_from_file {
    my ($self, $inputfile) = @_;

    open(FILE, $inputfile) or die $!;
    my @lines = <FILE>;
    chomp @lines;
    close(FILE);

    return \@lines;
}

=head2 _make_list_from_query
    
    Description: this is a private method that loads ids from a given sql query

    param('db_conn'): An optional hash to pass in connection parameters to the database upon which the query will have to be run.

=cut

sub _make_list_from_query {
    my ($self, $inputquery) = @_;

    my $dbc;
    if(my $db_conn = $self->param('db_conn')) {
        $dbc = DBI->connect("DBI:mysql:$db_conn->{-dbname}:$db_conn->{-host}:$db_conn->{-port}", $db_conn->{-user}, $db_conn->{-pass}, { RaiseError => 1 });
    } else {
        $dbc = $self->db->dbc;
    }

    my @ids = ();
    my $sth = $dbc->prepare($inputquery);
    $sth->execute();
    while (my ($id)=$sth->fetchrow_array()) {
        push @ids, $id;
    }
    $sth->finish();

    return \@ids;
}

=head2 _make_list_from_cmd
    
    Description: this is a private method that loads ids from a given command line

=cut

sub _make_list_from_cmd {
    my ($self, $inputcmd) = @_;

    my @lines = `$inputcmd`;
    chomp @lines;

    return \@lines;
}

=head2 _split_list_into_ranges
    
    Description: this is a private method that splits a list of ids into sub-ranges

=cut

sub _split_list_into_ranges {
    my ($self, $template_hash, $numeric, $list, $step) = @_;

    my @ranges = ();

    while(@$list) {
        my $range_start = shift @$list;
        my $range_end   = $range_start;
        my $range_count = 1;
        while($range_count<$step && @$list) {
            my $next_value     = shift @$list;
            my $predicted_next = $range_end;
            if(++$predicted_next eq $next_value) {
                $range_end = $next_value;
                $range_count++;
            } else {
                unshift @$list, $next_value;
                last;
            }
        }

        push @ranges, $self->_create_one_range_hash($template_hash, $numeric, $range_start, $range_end, $range_count);
    }
    return \@ranges;
}

=head2 _create_one_range_hash
    
    Description: this is a private method that transforms one range into an input_id hash using the param('input_id') template

=cut

sub _create_one_range_hash {
    my ($self, $template_hash, $numeric, $range_start, $range_end, $range_count) = @_;

    my %range_hash = (); # has to be a fresh hash every time

    while( my ($key,$value) = each %$template_hash) {

            # evaluate Perl-expressions after substitutions:
        if($value=~/\$Range/) {
            $value=~s/\$RangeStart/$range_start/g; 
            $value=~s/\$RangeEnd/$range_end/g; 
            $value=~s/\$RangeCount/$range_count/g; 

            if($numeric) {
                $value = eval($value);
            }
        }
        $range_hash{$key} = $value;
    }
    return \%range_hash;
}

=head2 _fisher_yates_shuffle_in_place
    
    Description: this is a private function (not a method) that shuffles a list of ids

=cut

sub _fisher_yates_shuffle_in_place {
    my $array = shift @_;

    for(my $upper=scalar(@$array);--$upper;) {
        my $lower=int(rand($upper+1));
        next if $lower == $upper;
        @$array[$lower,$upper] = @$array[$upper,$lower];
    }
}

1;

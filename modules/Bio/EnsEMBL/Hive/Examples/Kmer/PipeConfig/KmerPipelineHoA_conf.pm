=pod

=head1 NAME

Bio::EnsEMBL::Hive::Examples::Kmer::PipeConfig::KmerPipelineHoA_conf

=head1 SYNOPSIS

       # initialize the database and build the graph in it (it will also print the value of EHIVE_URL) :
    init_pipeline.pl Bio::EnsEMBL::Hive::Examples::Kmer::PipeConfig::KmerPipelineHoA_conf -password <mypass>

        # optionally also seed it with your specific values:
    seed_pipeline.pl -url $EHIVE_URL -logic_name split_sequence -input_id '{ "sequence_file" => "my_sequence.fa", "chunk_size" => 1000, "overlap_size" => 12 }'

        # run the pipeline:
    beekeeper.pl -url $EHIVE_URL -loop

=head1 DESCRIPTION

    This is the PipeConfig file for the Kmer counting pipeline example.
    This pipeline illustrates how to write PipeConfigs and Runnables that utilize the eHive features:
     * Factories creating a fan of jobs
     * Hash of array accumulator
     * Semaphores
     * Conditional pipeline flow

    Please refer to Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf module to understand the interface implemented here.

    Determining the frequency of k-mers (runs of nucleotides k bases long) is an important part of sequence analysis.
    This pipeline takes a flat file containing one or more sequences, counts the k-mers in them, then records
    the count of each k-mer in a table in the hive database.

    The pipeline can be run in two modes: short-sequence mode and long-sequence mode. These modes reflect two k-mer
    analysis use cases. 

    Short-sequence mode is useful for counting k-mers when the input contains many short (< a few kb) sequences. In this
    mode, the input file is chunked into several smaller files, each of which contains a subset of the sequences from
    the original input. The k-mers in these sequences are counted up in parallel. Then, the pipeline sums up all the
    k-mer counts from those individual sub-counts.

    Long-sequence mode is useful for counting k-mers when the input contains a few very long (> hundreds of kb) sequences.
    In this mode, the sequence or sequences in the input file are split into shorter subsequences, with overlapping ends.
    The k-mers in these subsequences are counted up in parallel. Then, the pipeline sums up all the k-mer counts from
    those individual subcounts.

    Selection of short- and long- sequence mode is done by setting the "seqtype" parameter. This parameter determines
    which analyses are included in the pipeline via eHive's conditional dataflow mechanism.

    Parameters:
    seqtype          => Can be 'short' or 'long' which determines whether the pipeline runs in short-sequence mode
                        or long-sequence mode (see descriptions above). The value determines which runnable the pipeline
                        will use to split the sequence
    input_format     => Format of the input sequence file (e.g. FASTA, FASTQ). Must be supported by Bio::SeqIO
    inputfile        => Name of input file
    chunk_size       => Size of sub-sequences or sub-files (in bases) - see the documentation in the FastaFactory
                        and SplitSequence runnables for details
    max_chunk_length => Maximum length of sequence in a sub-file - see the documentation in the FastaFactory
                        and SplitSequence runnables for details
    output_prefix    => Filename prefix for the intermediate split files generated by this pipeline
    output_suffix    => Filename suffix for the intermediate split files generated by this pipeline

=head1 LICENSE

    Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
    Copyright [2016] EMBL-European Bioinformatics Institute

    Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

         http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software distributed under the License
    is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and limitations under the License.

=head1 CONTACT

    Please subscribe to the Hive mailing list:  http://listserver.ebi.ac.uk/mailman/listinfo/ehive-users  to discuss Hive-related questions or to be notified of our updates

=cut

package Bio::EnsEMBL::Hive::Examples::Kmer::PipeConfig::KmerPipelineHoA_conf;

use strict;
use warnings;

use base ('Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf');  # All Hive databases configuration files should inherit from HiveGeneric, directly or indirectly
use Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf;           # Allow this particular config to use conditional dataflow

=head2 default_options

    Description : Implements the default_options() interface method of  Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf
    that sets default parameter values. These values can be overridden when running the init_pipeline.pl script.
    Here, we set defaults for:

    seqtype          => Can be 'short' or 'long' which determines whether the pipeline runs in short-sequence mode
                        or long-sequence mode (see descriptions above). The value determines which runnable the pipeline
                        will use to split the sequence
    input_format     => Format of the input sequence file (e.g. FASTA, FASTQ). Must be supported by Bio::SeqIO
    inputfile        => Name of input file
    chunk_size       => Size of sub-sequences or sub-files (in bases) - see the documentation in the FastaFactory
                        and SplitSequence runnables for details
    output_prefix    => Filename prefix for the intermediate split files generated by this pipeline
    output_suffix    => Filename suffix for the intermediate split files generated by this pipeline

=cut

sub default_options {
  my ($self) = @_;

  return {
	  %{ $self->SUPER::default_options() },               # inherit other stuff from the base class
	  'seqtype' => 'short',
	  'input_format' => 'FASTA',
	  # init_pipeline makes a best guess of the hive root directory and stores
          # it in EHIVE_ROOT_DIR, if it is not already set in the shell
	  'inputfile' => $ENV{'EHIVE_ROOT_DIR'} . '/t/input_fasta.fa',
	  'chunk_size' => 40,
	  'output_prefix' => 'k_split_',
	  'output_suffix' => '.fa',
	 };
}

=head2 pipeline_create_commands

    Description : Implements pipeline_create_commands() interface method of Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf that lists the commands that will create and set up the Hive database.
                  In addition to the standard creation of the database and populating it with Hive tables and procedures it also creates a table to hold this pipeline's final result.

=cut

sub pipeline_create_commands {
    my ($self) = @_;
    return [
        @{$self->SUPER::pipeline_create_commands},  # inheriting database and hive tables' creation

        # additional table to store results:
        $self->db_cmd('CREATE TABLE final_result (filename VARCHAR(255) NOT NULL, kmer VARCHAR(255) NOT NULL, count INT NOT NULL, PRIMARY KEY (filename, kmer))'),
    ];
}


=head2 pipeline_wide_parameters

    Description : Interface method that should return a hash of pipeline_wide_parameter_name->pipeline_wide_parameter_value pairs.
                  The value doesn't have to be a scalar, can be any Perl structure now (will be stringified and de-stringified automagically).
                  Please see existing PipeConfig modules for examples.

=cut

sub pipeline_wide_parameters {
    my ($self) = @_;
    return {
        %{$self->SUPER::pipeline_wide_parameters},          # here we inherit anything from the base class
    };
}

=head2 hive_meta_table

    Description: Interface method that should return a hash of meta-information about the pipeline (e.g. pipeline name or schema version).
                 Here, we indicate that this pipeline should use the parameter stack by setting 'hive_use_param_stack' to 1.

=cut

sub hive_meta_table {
    my ($self) = @_;
    return {
        %{$self->SUPER::hive_meta_table},       # here we inherit anything from the base class

        'hive_use_param_stack'  => 1,           # switch on the param_stack mechanism
    };
}

=head2 pipeline_analyses

    Description : Implements pipeline_analyses() interface method of Bio::EnsEMBL::Hive::PipeConfig::HiveGeneric_conf that defines the structure of the pipeline: analyses, jobs, rules, etc.
                  Here it defines these analyses:

                  * split_strategy      -- This analysis uses the runnable Bio::EnsEMBL::Hive::RunnableDB::Dummy. It performs no work in itself;
                                           rather it exists to trigger dataflow. The interesting part of this pipeline is the WHEN-ELSE flow control
                                           in the flow_into section of the analysis definition. Here, subsequent analyses are determined based
                                           on the value in the "seqtype" parameter.
                  * split_sequence      -- This analysis uses the runnable Bio::EnsEMBL::Hive::Examples::Kmer::RunnableDB::SplitSequence.
                                           It splits sequences in an input-file with overlap, and stores the subsequences in a collection of
                                           output files. In this pipeline, flow goes from split_strategy into split_sequence when the "seqtype"
                                           parameter is not "short."
                  * chunk_sequence      -- This analysis uses the runnable Bio::EnsEMBL::Hive::RunnableDB::FastaFactory. It splits a file
                                           containing many sequences into a collection of sub-files, each containing a few of the sequences from
                                           the original input file. Individual sequences are kept intact (unlike SplitSequence). In this pipeline,
                                           flow goes from split_strategy into chunk_sequence when the "seqtype" parameter is "short."
                  * count_kmers         -- This analysis uses the runnable Bio::EnsEMBL::Hive::Examples::Kmer::RunnableDB::CountKmers, which
                                           identifies and tallies k-mers in the sequences in an input file. This pipeline is designed to create
                                           several count_kmers jobs in parallel, the fan of jobs being created by either split_sequence or chunk_sequence.
                  * compile_counts      -- This analysis uses the runnable Bio::EnsEMBL::Hive::Examples::Kmer::RunnableDB::CompileCounts.
                                           In this pipeline, a compile_counts job is created but it is initially blocked from running
                                           by a semaphore. When all count_kmers jobs have finished, the semaphore is cleared, allowing a worker
                                           to claim the compile_counts job and run it. This job compiles all the k-mer counts from
                                           the previous count_kmers jobs into overall counts for each k-mer.

=cut

sub pipeline_analyses {
  my ($self) = @_;
  return [
	  {-logic_name => 'split_strategy',
	   -module     => 'Bio::EnsEMBL::Hive::RunnableDB::Dummy',
	   -meadow_type => 'LOCAL', # do not bother the farm with such a simple task (and get it done faster)
	   -input_ids => [
	  		  { 'seqtype' => $self->o('seqtype'),
	  		    'input_format' => $self->o('input_format'),
	  		    'inputfile' => $self->o('inputfile'),
	  		    'chunk_size' => $self->o('chunk_size'),
	  		    'output_prefix' => $self->o('output_prefix'),
	  		    'output_suffix' => $self->o('output_suffix'),
			    'k' => $self->o('k'),
	  		  },
	  		 ],
	   -flow_into => {
			  # use conditional dataflow to determine the next analysis, based on the value of the "seqtype" parameter
	  		  '1->A' => WHEN('#seqtype# eq "short"' => [ 'chunk_sequence' ],
					 ELSE [ 'split_sequence' ]),
			  # creating a semaphored funnel job to wait for the fan to complete and add the results:
			  'A->1' => [ 'compile_counts' ],
	  		 },
	   
	  },

	  {   -logic_name => 'split_sequence',
	      -module     => 'Bio::EnsEMBL::Hive::Examples::Kmer::RunnableDB::SplitSequence',
	      # here, a template is used to perform a calculation on a parameter
	      -parameters => { "overlap_size" => "#expr(#k#-1)expr#"},
	      -analysis_capacity  =>  2,  # use per-analysis limiter
	      -flow_into => {
	  		     '2' => ['count_kmers'],
	  		    },
	  },
	  
	  { -logic_name => 'chunk_sequence',
	    -module => 'Bio::EnsEMBL::Hive::RunnableDB::FastaFactory',
	    -parameters => { "max_chunk_length" => "#chunk_size#" },
	    -flow_into => {			   
	  		   '2' => ['count_kmers'],
	  		  },
	  },
	  
	  {   -logic_name => 'count_kmers',
	      -module     => 'Bio::EnsEMBL::Hive::Examples::Kmer::RunnableDB::CountKmers',
	      # Here, we use a template to rename a parameter.
	      -parameters => { 
	  		       "sequence_file" => '#chunk_name#',
	  		     },
	      -analysis_capacity  =>  4,  # use per-analysis limiter
	      -flow_into => {
			     # Flows into a hash accumulator called all_counts. The hash key is a string with the kmer
			     # sequence: it is dataflown out in a parameter called 'kmer', and we indicate it is to
                             # be the hash key in the 'accu_address={kmer}' portion of the url below. The value for
			     # each key is dataflown out in a parameter called 'count'; the
			     # 'accu_input_variable=count' portion of the url is where it's set as the value.
			     # The name of the Accumulator is 'all_counts', as designated by 'accu_name=all_counts' in the url.
			     # It is allowed to use the same name as the input variable, in which case accu_name could be skipped
	  		     4 => [ '?accu_name=all_counts&accu_address={kmer}[]&accu_input_variable=count' ],
	  		    },
	  },
	  
	  {   -logic_name => 'compile_counts',
	      -module     => 'Bio::EnsEMBL::Hive::Examples::Kmer::RunnableDB::CompileCountsHoA',
	      -flow_into => {
			     # Flows the output into a table in the hive database called 'final_result'.
			     # We created this table earlier in this conf file during pipeline_create_commands().
			     # It has two columns, 'kmer' and 'count', which are filled in by params with matching
			     # names that are dataflown out.
	  		     4 => [ '?table_name=final_result' ],
	  		    },
	  },
	 ];
}

1;

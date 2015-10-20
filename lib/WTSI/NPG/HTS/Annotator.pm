package WTSI::NPG::HTS::Annotator;

use List::AllUtils qw(uniq);
use Moose::Role;

use WTSI::NPG::iRODS::Metadata;

use st::api::lims;
use st::api::lims::ml_warehouse;

our $VERSION = '';

with 'WTSI::DNAP::Utilities::Loggable', 'WTSI::NPG::iRODS::Utilities';

=head2 make_hts_metadata

  Arg [1]    : WTSI::DNAP::Warehouse::Schema multi-LIMS schema
  Arg [2]    : Int run identifier
  Arg [3]    : Int flowcell lane position
  Arg [4]    : Int tag index. Optional.

  Example    : $ann->make_hts_metadata($schema, 3002, 3, 1)
  Description: Return an array of metadata AVUs describing the HTS data
               in the specified run/lane/plex.
  Returntype : Array[HashRef]

=cut

## no critic (Subroutines::ProhibitManyArgs)
sub make_hts_metadata {
  my ($self, $schema, $id_run, $position, $tag_index,
      $with_spiked_control) = @_;

  defined $schema or $self->logconfess('A defined schema argument is required');
  defined $id_run or $self->logconfess('A defined id_run argument is required');
  defined $position or
    $self->logconfess('A defined position argument is required');

  my ($flowcell_barcode, $flowcell_id) =
    $self->_find_barcode_and_lims_id($schema, $id_run);

  my @initargs = (flowcell_barcode => $flowcell_barcode,
                  id_flowcell_lims => $flowcell_id,
                  position         => $position,
                  tag_index        => $tag_index);
  my $driver = st::api::lims::ml_warehouse->new
    (mlwh_schema => $schema, @initargs);
  my $lims = st::api::lims->new(driver => $driver,
                                id_run => $id_run,
                                @initargs);

  my @meta;

  push @meta, $self->make_consent_metadata($lims);
  push @meta, $self->make_run_metadata($lims);
  push @meta, $self->make_plex_metadata($lims);

  push @meta, $self->make_study_metadata($lims, $with_spiked_control);
  push @meta, $self->make_sample_metadata($lims, $with_spiked_control);
  push @meta, $self->make_library_metadata($lims, $with_spiked_control);

  return @meta;
}
## use critic

=head2 make_run_metadata

  Arg [1]    : WTSI::DNAP::Warehouse::Schema::Result::IseqRunLaneMetric

  Example    : $ann->make_run_metadata($rlm);
  Description: Return HTS run metadata.
  Returntype : Array[HashRef]

=cut

sub make_run_metadata {
  my ($self, $lims) = @_;

  # Map of method name to attribute name under which the result will
  # be stored.
  my $method_attr = {id_run   => $ID_RUN,
                     position => $POSITION};
  return $self->_make_single_value_metadata($lims, $method_attr);
}

=head2 make_study_metadata

  Arg [1]    : WTSI::DNAP::Warehouse::Schema::Result::IseqProductMetric

  Example    : $ann->make_study_metadata($pm);
  Description: Return HTS study metadata.
  Returntype : Array[HashRef]

=cut

sub make_study_metadata {
  my ($self, $lims, $with_spiked_control) = @_;

  # Map of method name to attribute name under which the result will
  # be stored.
  my $method_attr =
    {study_accession_numbers => $STUDY_ACCESSION_NUMBER,
     study_names             => $STUDY_NAME,
     study_ids               => $STUDY_ID,
     study_titles            => $STUDY_TITLE};

  return $self->_make_multi_value_metadata($lims, $method_attr,
                                           $with_spiked_control);
}

=head2 make_sample_metadata

  Arg [1]    : WTSI::DNAP::Warehouse::Schema::Result::IseqProductMetric

  Example    : $ann->make_sample_metadata($pm);
  Description: Return HTS sample metadata.
  Returntype : Array[HashRef]

=cut

sub make_sample_metadata {
  my ($self, $lims, $with_spiked_control) = @_;

  # Map of method name to attribute name under which the result will
  # be stored.
  my $method_attr =
    {sample_names          => $SAMPLE_NAME,
     sample_public_names   => $SAMPLE_PUBLIC_NAME,
     sample_common_names   => $SAMPLE_COMMON_NAME,
     sample_supplier_names => $SAMPLE_SUPPLIER_NAME,
     sample_cohorts        => $SAMPLE_COHORT,
     sample_donor_ids      => $SAMPLE_DONOR_ID};

  return $self->_make_multi_value_metadata($lims, $method_attr,
                                           $with_spiked_control);
}

sub make_consent_metadata {
  my ($self, $lims) = @_;

  my $attr  = $SAMPLE_CONSENT_WITHDRAWN;
  my $value = $lims->any_sample_consent_withdrawn;

  return ($self->make_avu($attr, $value));
}

=head2 make_library_metadata

  Arg [1]    : WTSI::DNAP::Warehouse::Schema::Result::IseqProductMetric

  Example    : $ann->make_library_metadata($pm);
  Description: Return HTS library metadata.
  Returntype : Array[HashRef]

=cut

sub make_library_metadata {
  my ($self, $lims, $with_spiked_control) = @_;

  # Map of method name to attribute name under which the result will
  # be stored.
  my $method_attr = {library_ids => $LIBRARY_ID};

  return $self->_make_multi_value_metadata($lims, $method_attr,
                                           $with_spiked_control);
}

=head2 make_plex_metadata

  Arg [1]    :  WTSI::DNAP::Warehouse::Schema::Result::IseqProductMetric

  Example    : $ann->make_plex_metadata($pm);
  Description: Return HTS plex metadata.
  Returntype : Array[HashRef]

=cut

sub make_plex_metadata {
  my ($self, $lims) = @_;

  # Map of method name to attribute name under which the result will
  # be stored.
  my $method_attr = {tag_index => $TAG_INDEX,
                     qc_state  => $QC_STATE};
  return $self->_make_single_value_metadata($lims, $method_attr);
}

sub _make_single_value_metadata {
  my ($self, $lims, $method_attr) = @_;
  # The method_attr argument is a map of method name to attribute name
  # under which the result will be stored.

  my @avus;
  foreach my $method_name (sort keys %{$method_attr}) {
    my $attr  = $method_attr->{$method_name};
    my $value = $lims->$method_name;

    if (defined $value) {
      push @avus, $self->make_avu($attr, $value);
    }
  }

  return @avus;
}

sub _make_multi_value_metadata {
  my ($self, $lims, $method_attr, $with_spiked_control) = @_;
  # The method_attr argument is a map of method name to attribute name
  # under which the result will be stored.

  my @avus;
  foreach my $method_name (sort keys %{$method_attr}) {
    my $attr = $method_attr->{$method_name};

    foreach my $value ($lims->$method_name($with_spiked_control)) {
      push @avus, $self->make_avu($attr, $value);
    }
  }

  return @avus;
}

sub _find_barcode_and_lims_id {
  my ($self, $schema, $id_run) = @_;

  my $flowcell = $schema->resultset('IseqFlowcell')->search
    ({'iseq_product_metrics.id_run' => $id_run},
     {join     => 'iseq_product_metrics',
      select   => ['flowcell_barcode', 'id_flowcell_lims'],
      distinct => 1});

  # FIXME
  my @result;
  while (my $fc = $flowcell->next) {
    push @result, $fc->flowcell_barcode, $fc->id_flowcell_lims;
  }

  return @result;
}

no Moose::Role;

1;

__END__

=head1 NAME

WTSI::NPG::HTS::Annotator

=head1 DESCRIPTION

A role providing methods to calculate metadata for WTSI HTS runs.

=head1 AUTHOR

Keith James <kdj@sanger.ac.uk>

=head1 COPYRIGHT AND DISCLAIMER

Copyright (C) 2015 Genome Research Limited. All Rights Reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the Perl Artistic License or the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut
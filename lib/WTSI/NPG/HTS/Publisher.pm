package WTSI::NPG::HTS::Publisher;

use namespace::autoclean;
use Data::Dump qw(pp);
use DateTime;
use English qw(-no_match_vars);
use File::Spec::Functions qw(catfile splitpath);
use Moose;
use Try::Tiny;

use WTSI::NPG::iRODS::DataObject;
use WTSI::NPG::iRODS;

with 'WTSI::DNAP::Utilities::Loggable', 'WTSI::NPG::Accountable',
  'WTSI::NPG::HTS::Annotator';

our $VERSION = '';

has 'irods' =>
  (is       => 'ro',
   isa      => 'WTSI::NPG::iRODS',
   required => 1,
   default  => sub {
     return WTSI::NPG::iRODS->new;
   });


sub BUILD {
  my ($self) = @_;

  $self->irods->logger($self->logger);
  return;
}

sub publish {
  my ($self, $local_path, $remote_path, $metadata, $timestamp) = @_;

  my $published;
  if (-f $local_path) {
    $published = $self->publish_file($local_path, $remote_path, $metadata,
                                     $timestamp);
  }
  elsif (-d $local_path) {
    $published = $self->publish_directory($local_path, $remote_path, $metadata,
                                          $timestamp);
  }
  else {
    $self->logconfess('The local_path argument as neither a file nor a ',
                      'directory: ', "'$local_path'");
  }

  return $published;
}

=head2 publish_file

  Arg [1]    : Path to local file, Str.
  Arg [2]    : Path to destination in iRODS, Str.
  Arg [3]    : Custom metadata AVUs to add, ArrayRef[HashRef].
  Arg [4]    : Timestamp to use in metadata, DateTime. Optional, defaults
               to current time.

  Example    : my $path = $pub->publish_file('./local/file.txt',
                                             '/zone/path/file.txt',
                                             [{attribute => 'x',
                                               value     => 'y'}])
  Description: Publish a local file to iRODS, create and/or supersede
               metadata (both default and custom) and update permissions,
               returning the absolute path of the published data object.

               If the target path does not exist in iRODS the file will
               be transferred. Default creation metadata will be added and
               custom metadata will be added.

               If the target path exists in iRODS, the checksum of the
               local file will be compared with the cached checksum in
               iRODS. If the checksums match, the local file will not
               be uploaded. Default modification metadata will be added
               and custom metadata will be superseded.

               In both cases, permissions will be updated.
  Returntype : Str

=cut

sub publish_file {
  my ($self, $local_path, $remote_path, $metadata, $timestamp) = @_;

  $self->_check_path_args($local_path, $remote_path);
  -f $local_path or
    $self->logconfess("The local_path argument '$local_path' was not a file");

  if (defined $metadata and ref $metadata ne 'ARRAY') {
    $self->logconfess('The metadata argument must be an ArrayRef');
  }
  if (not defined $timestamp) {
    $timestamp = DateTime->now;
  }

  my $obj;
  if ($self->irods->is_collection($remote_path)) {
    $self->info("Remote path '$remote_path' is a collection");

    my ($loc_vol, $dir, $file) = splitpath($local_path);
    $obj = $self->publish_file($local_path, catfile($remote_path, $file),
                               $metadata, $timestamp)
  }
  else {
    my $local_md5 = $self->irods->md5sum($local_path);
    if ($self->irods->is_object($remote_path)) {
      $self->info("Remote path '$remote_path' is an existing object");
      $obj = $self->_publish_file_overwrite($local_path, $local_md5,
                                            $remote_path, $timestamp);
    }
    else {
      $self->info("Remote path '$remote_path' is a new object");
      $obj = $self->_publish_file_create($local_path, $local_md5,
                                         $remote_path, $timestamp);
    }

    my $num_meta_errors = 0;
    if (defined $metadata) {
      foreach my $avu (@{$metadata}) {
        try {
          $obj->supersede_multivalue_avus($avu->{attribute}, [$avu->{value}],
                                          $avu->{units});
        } catch {
          $num_meta_errors++;
          $self->error('Failed to supersede with AVU ', pp($avu), ': ', $_);
        };
      }
    }

    if ($num_meta_errors > 0) {
       $self->logcroak("Failed to update metadata on '$remote_path': ",
                       "$num_meta_errors errors encountered ",
                       '(see log for details)');
     }
  }

  return $obj->str;
}

# sub publish_directory {
#   my ($self, $local_path, $remote_path, $metadata, $timestamp) = @_;

#   $self->_check_path_args($local_path, $remote_path);
#   -d $local_path or
#     $self->logconfess("The local_path argument '$local_path' ",
#                       'was not a directory');

#   if (defined $metadata and ref $metadata ne 'ARRAY') {
#     $self->logconfess('The metadata argument must be an ArrayRef');
#   }
#   if (not defined $timestamp) {
#     $timestamp = DateTime->now;
#   }

#   my $coll = $self->_ensure_collection($remote_path);

#   return $coll;
# }

sub _check_path_args {
  my ($self, $local_path, $remote_path) = @_;

  defined $local_path or
    $self->logconfess('A defined local_path argument is required');
  defined $remote_path or
    $self->logconfess('A defined remote_path argument is required');

  $local_path eq q{} and
    $self->logconfess('A non-empty local_path argument is required');
  $remote_path eq q{} and
    $self->logconfess('A non-empty remote_path argument is required');

  $remote_path =~ m{^/}msx or
    $self->logconfess("The remote_path argument '$remote_path' ",
                      'was not absolute');

  return;
}

sub _ensure_collection {
  my ($self, $remote_path) = @_;

  my $collection;
  if ($self->irods->is_object($remote_path)) {
    $self->logconfess("The remote_path argument '$remote_path' ",
                      'was a data object');
  }
  elsif ($self->irods->is_collection($remote_path)) {
    $self->debug("Remote path '$remote_path' is a collection");
    $collection = $remote_path;
  }
  else {
    $collection = $self->irods->add_collection($remote_path);
  }

  return $collection;
}

sub _publish_file_create {
  my ($self, $local_path, $local_md5, $remote_path, $timestamp) = @_;

  $self->debug("Remote path '$remote_path' does not exist");
  my ($loc_vol, $dir, $file)      = splitpath($local_path);
  my ($rem_vol, $coll, $obj_name) = splitpath($remote_path);

  if ($file ne $obj_name) {
    $self->info("Renaming '$file' to '$obj_name' on publication");
  }

  $self->_ensure_collection($coll);
  $self->info("Publishing new object '$remote_path'");

  $self->irods->add_object($local_path, $remote_path);

  my $obj = WTSI::NPG::iRODS::DataObject->new($self->irods, $remote_path);
  my $num_meta_errors = 0;

  my $remote_md5 = $obj->checksum; # Calculated on publication
  my @meta = $self->make_creation_metadata($self->affiliation_uri,
                                           $timestamp,
                                           $self->accountee_uri);
  push @meta, $self->make_md5_metadata($remote_md5);
  push @meta, $self->make_type_metadata($remote_path);

  foreach my $avu (@meta) {
    try {
      $obj->supersede_avus($avu->{attribute}, $avu->{value}, $avu->{units});
    } catch {
      $num_meta_errors++;
      $self->error('Failed to supersede with AVU ', pp($avu), ': ', $_);
    };
  }

  if ($local_md5 eq $remote_md5) {
    $self->info("After publication of '$local_path' ",
                "MD5: '$local_md5' to '$remote_path' ",
                "MD5: '$remote_md5': checksums match");
  }
  else {
    # Maybe tag with metadata to identify a failure?
    $self->logcroak("After publication of '$local_path' ",
                    "MD5: '$local_md5' to '$remote_path' ",
                    "MD5: '$remote_md5': checksum mismatch");
  }

  if ($num_meta_errors > 0) {
    $self->logcroak("Failed to update metadata on '$remote_path': ",
                    "$num_meta_errors errors encountered ",
                    '(see log for details)');
  }

  return $obj;
}

sub _publish_file_overwrite {
  my ($self, $local_path, $local_md5, $remote_path, $timestamp) = @_;

  $self->info("Remote path '$remote_path' is a data object");
  my $obj = WTSI::NPG::iRODS::DataObject->new($self->irods, $remote_path);
  my $num_meta_errors = 0;

  my $pre_remote_md5 = $obj->calculate_checksum;
  if ($local_md5 eq $pre_remote_md5) {
    $self->info("Skipping publication of '$local_path' to '$remote_path': ",
                "(checksum unchanged): local MD5 is '$local_md5', ",
                "remote is MD5: '$pre_remote_md5'");
  }
  else {
    $self->info("Re-publishing '$local_path' to '$remote_path' ",
                "(checksum changed): local MD5 is '$local_md5', ",
                "remote is MD5: '$pre_remote_md5'");
    $self->irods->replace_object($local_path, $obj->str);

    my $post_remote_md5 = $obj->checksum; # Calculated on publication
    my @meta = $self->make_modification_metadata($timestamp);
    push @meta, $self->make_md5_metadata($post_remote_md5);
    push @meta, $self->make_type_metadata($remote_path);

    foreach my $avu (@meta) {
      try {
        $obj->supersede_avus($avu->{attribute}, $avu->{value},
                             $avu->{units});
      } catch {
        $num_meta_errors++;
        $self->error('Failed to supersede with AVU ', pp($avu), ': ', $_);
      };
    }

    if ($local_md5 eq $post_remote_md5) {
      $self->info("Re-published '$local_path' to '$remote_path': ",
                  "(checksums match): local MD5 was '$local_md5', ",
                  "remote was MD5: '$pre_remote_md5', ",
                  "remote now MD5: '$post_remote_md5'");
    }
    elsif ($pre_remote_md5 eq $post_remote_md5) {
      # Maybe tag with metadata to identify a failure?
      $self->logcroak("Failed to re-publish '$local_path' to '$remote_path': ",
                      "(checksum unchanged): local MD5 was '$local_md5', ",
                      "remote was MD5: '$pre_remote_md5', ",
                      "remote now MD5: '$post_remote_md5'");
    }
    else {
      # Maybe tag with metadata to identify a failure?
      $self->logcroak("Failed to re-publish '$local_path' to '$remote_path': ",
                      "(checksum mismatch): local MD5 was '$local_md5', ",
                      "remote was MD5: '$pre_remote_md5', ",
                      "remote now MD5: '$post_remote_md5'");
    }
  }

  if ($num_meta_errors > 0) {
    $self->logcroak("Failed to update metadata on '$remote_path': ",
                    "$num_meta_errors errors encountered ",
                    '(see log for details)');
  }

  return $obj;
}

no Moose;

1;

__END__

=head1 NAME

WTSI::NPG::HTS::Publisher

=head1 DESCRIPTION

General purpose file/metadata publisher for iRODS.

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
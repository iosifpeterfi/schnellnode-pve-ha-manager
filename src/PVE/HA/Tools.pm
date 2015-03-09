package PVE::HA::Tools;

use strict;
use warnings;
use JSON; 
use PVE::Tools;

sub read_json_from_file {
    my ($filename, $default) = @_;

    my $data;

    if (defined($default) && (! -f $filename)) {
	$data = $default;
    } else {
	my $raw = PVE::Tools::file_get_contents($filename);
	$data = decode_json($raw);
    }

    return $data;
}

sub write_json_to_file {
    my ($filename, $data) = @_;

    my $raw = encode_json($data);
 
    PVE::Tools::file_set_contents($filename, $raw);
}


1;

package PVE::HA::Resources;

use strict;
use warnings;

use Data::Dumper;
use PVE::JSONSchema qw(get_standard_option);
use PVE::SectionConfig;
use PVE::HA::Tools;

use base qw(PVE::SectionConfig);

my $defaultData = {
    propertyList => {
	type => { description => "Resource type.", optional => 1 },
	sid => get_standard_option('pve-ha-resource-id'),
	state => {
	    description => "Resource state.",
	    type => 'string',
	    enum => ['enabled', 'disabled'],
	    optional => 1,
	    default => 'enabled',
	},
	group => get_standard_option('pve-ha-group-id', { optional => 1 }),
	comment => {
	    description => "Description.",
	    type => 'string',
	    optional => 1,
	    maxLength => 4096,
	},
    },
};

sub verify_name {
    my ($class, $name) = @_;

    die "implement this in subclass";
}

sub private {
    return $defaultData;
}

sub format_section_header {
    my ($class, $type, $sectionId) = @_;

    my (undef, $name) = split(':', $sectionId, 2);
    
    return "$type: $name\n";
}

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
	my ($type, $name) = (lc($1), $2);
	my $errmsg = undef; # set if you want to skip whole section
	eval {
	    if (my $plugin = $defaultData->{plugins}->{$type}) {
		$plugin->verify_name($name);
	    } else {
		die "no such resource type '$type'\n";
	    }
	};
	$errmsg = $@ if $@;
	my $config = {}; # to return additional attributes
	return ($type, "$type:$name", $errmsg, $config);
    }
    return undef;
}

package PVE::HA::Resources::PVEVM;

use strict;
use warnings;

use base qw(PVE::HA::Resources);

sub type {
    return 'vm';
}

sub verify_name {
    my ($class, $name) = @_;

    die "invalid VMID\n" if $name !~ m/^[1-9][0-9]+$/;
}

sub options {
    return {
	state => { optional => 1 },
	group => { optional => 1 },
	comment => { optional => 1 },
    };
}

# package PVE::HA::Resources::IPAddr;

# use strict;
# use warnings;
# use PVE::Tools qw($IPV4RE $IPV6RE);

# use base qw(PVE::HA::Resources);

# sub type {
#     return 'ipaddr';
# }

# sub verify_name {
#     my ($class, $name) = @_;

#     die "invalid IP address\n" if $name !~ m!^$IPV6RE|$IPV4RE$!;
# }

# sub options {
#     return {
# 	state => { optional => 1 },
# 	group => { optional => 1 },
# 	comment => { optional => 1 },
#     };
# }

1;

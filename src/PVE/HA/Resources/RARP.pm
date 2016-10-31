package Packet::RARP;
#
# $Id: RARP.pm,v 1.7 2002/05/09 05:16:56 tcaine Exp $

use strict;

use vars qw/ $VERSION @ISA /;
$VERSION = '0.01';

use Packet;
@ISA = qw/ Packet /;

use Packet::Lookup qw/ :mac :ip /;

use overload '""' => sub { encode($_[0]) };


#  Object Methods

#  generate accessor methods
foreach ( qw( opcode htype proto sender_eth target_eth sender_ip target_ip plen hlen ) ) {
    eval "sub $_ () { (\@_ > 1) ? \$_[0]->{$_} = \$_[1] : \$_[0]->{$_} }";
}

sub new {
  my ($class, %args) = @_;
  my $self = {
    opcode	=> 3,
    htype	=> 1,
    proto 	=> 0x0800,
    sender_eth	=> "ffffffffffff",
    target_eth	=> "ffffffffffff",
    sender_ip	=> "00000000",
    target_ip	=> "00000000",
    plen	=> 4,
    hlen	=> 6,
    %args
  };	

  return bless $self, ref($class) || $class;
}

sub encode {
  my ($self) = @_;

  $self->{target_ip} = ip_to_int(host_to_ip($self->{target_ip})) if $self->{target_ip} =~ /\./;
  $self->{sender_ip} = ip_to_int(host_to_ip($self->{sender_ip})) if $self->{sender_ip} =~ /\./;
  $self->{target_eth} = to_mac($self->{target_eth}) if $self->{target_eth} =~ /:/;
  $self->{source_eth} = to_mac($self->{sender_eth}) if $self->{sender_eth} =~ /:/;

  my $pkt = pack(
   'n			n			C
    C			n			H12
    H8			H12			H8',
    $self->{htype},	$self->{proto},		$self->{hlen},
    $self->{plen},	$self->{opcode},	$self->{sender_eth},
    $self->{sender_ip},	$self->{target_eth},	$self->{target_ip}
  );

  return $pkt;
}

sub decode {
  my ($self, $pkt) = @_;

  ($self->{htype},	$self->{proto},		$self->{hlen},
   $self->{plen},	$self->{opcode},	$self->{sender_eth},
   $self->{sender_ip},	$self->{target_eth},	$self->{target_ip}) = unpack(
  'n			n			C
   C			n			H12
   H8			H12			H8', $pkt
  );

  return 1;
}


1;
__END__

=head1 NAME

Packet::RARP - generate, encode, decode, and dump RARP packets.

=head1 SYNOPSIS

  use Packet::RARP;

  $i = Packet::RARP->new(
    opcode     => 1,
    sender_ip  => '10.0.0.1',
    sender_eth => 'a0:b1:c2:d3:e4:f5',
    target_ip  => '255.255.255.255',
    target_eth => 'ff:ff:ff:ff:ff:ff',
  );
  $raw_rarp = $i->encode();

  $i = Packet::RARP->new();
  $i->decode($raw_rarp); 

  print "eth addrs: " . $i->sender_eth . ' -> ' . $i->target_eth . "\n";
  print "ip addrs:  " . $i->sender_ip  . ' -> ' . $i->target_ip  . "\n";
  print "type: " . ($i->opcode == 1 ? "request" : ($i->opcode == 2 ? "reply : "unknown")) . "\n";

  print "packet dump:\n" . $i->hexdump($raw_rarp) . "\n";

=head1 DESCRIPTION

Packet::RARP is an *all Perl* module for creating and manipulating RARP packets.

=head1 AUTHORS

Samy Kamkar	<cp5@LucidX.com>

Todd Caine	<tcaine@eli.net>

=head1 SEE ALSO

Packet.pm

=cut


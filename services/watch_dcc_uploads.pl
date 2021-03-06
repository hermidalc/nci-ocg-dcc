#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib/perl5";
use sigtrap qw( handler sig_handler normal-signals error-signals ALRM );
use Email::Sender::Simple qw( try_to_sendmail );
use Email::Simple;
use Email::Simple::Creator;
use File::Basename qw( dirname );
use File::ChangeNotify;
use File::Spec;
use Getopt::Long qw( :config auto_help auto_version );
use List::MoreUtils qw( firstidx firstval );
use NCI::OCGDCC::Utils qw( load_configs );
use Pod::Usage qw( pod2usage );
use Sort::Key::Natural qw( natsort );
use Sys::Hostname;
use Data::Dumper;

sub sig_handler {
    die "[", scalar localtime, "] Stopping watcher\n";
}

our $VERSION = '0.1';

# Unbuffer error and output streams (make sure STDOUT is last so that it remains the default filehandle)
select(STDERR); $| = 1;
select(STDOUT); $| = 1;

$Data::Dumper::Terse = 1;
$Data::Dumper::Deepcopy = 1;
#$Data::Dumper::Indent = 1;
$Data::Dumper::Sortkeys = sub {
    my ($hashref) = @_;
    my @sorted_keys = natsort keys %{$hashref};
    return \@sorted_keys;
};

# config
my $config_hashref = load_configs(qw(
    common
    services
));
my $email_from_address =
    $config_hashref->{'services'}->{'watch_dcc_uploads'}->{'email_from_address_prefix'} .
    hostname .
    $config_hashref->{'services'}->{'watch_dcc_uploads'}->{'email_from_address_suffix'};
my @email_to_addresses = @{$config_hashref->{'services'}->{'watch_dcc_uploads'}->{'email_to_addresses'}};
my @email_cc_addresses = @{$config_hashref->{'services'}->{'watch_dcc_uploads'}->{'email_cc_addresses'}};
my %program_config = %{$config_hashref->{'services'}->{'watch_dcc_uploads'}->{'program_config'}};
my %data_type_dir_names = map { $_ => 1 } @{$config_hashref->{'common'}->{'data_types'}};
my $debug = 0;
GetOptions(
    'debug' => \$debug,
) || pod2usage(-verbose => 0);
if ($< != 0) {
    pod2usage(
        -message => 'Service must be run as root or with sudo',
        -verbose => 0,
    );
}
pod2usage(
    -message => 'Missing required parameter: sleep interval (in seconds)',
    -verbose => 0,
) unless @ARGV;
my $watcher_sleep_interval = shift @ARGV;
my (@dirs_to_watch, @dirs_to_exclude);
for my $program_name (keys %program_config) {
    for my $dir_to_watch (@{$program_config{$program_name}{'dirs_to_watch'}}) {
        if (!-d $dir_to_watch) {
            die "Invalid directory $dir_to_watch\n";
        }
        push @dirs_to_watch, $dir_to_watch;
    }
    for my $dir_to_exclude (@{$program_config{$program_name}{'dirs_to_exclude'}}) {
        push @dirs_to_exclude, $dir_to_exclude;
    }
}
print "[", scalar localtime, "] Starting watcher \n",
      "[", scalar localtime, "] Directories: ", join('; ', @dirs_to_watch), "\n",
      "[", scalar localtime, "] Exclude: ", join('; ', @dirs_to_exclude), "\n",
      "[", scalar localtime, "] Sleep interval: $watcher_sleep_interval seconds\n";
my $watcher = File::ChangeNotify->instantiate_watcher(
    directories => \@dirs_to_watch,
    exclude => \@dirs_to_exclude,
);
my %event_data_by_program_dataset;
while (1) {
    if (my @events = $watcher->new_events()) {
        for my $event (@events) {
            # file create events
            if ($event->type eq 'create' and -f $event->path) {
                for my $program_name (keys %program_config) {
                    if (my $base_dir = firstval { $event->path =~ /^\Q$_\E/ } @{$program_config{$program_name}{'dirs_to_watch'}}) {
                        my $event_dir = -d $event->path ? $event->path : dirname($event->path);
                        my @event_dir_parts = File::Spec->splitdir($event_dir);
                        my $data_type_dir_name_idx = firstidx { exists $data_type_dir_names{$_} } @event_dir_parts;
                        my $dataset_dir = File::Spec->catdir(
                            $data_type_dir_name_idx >= 0 ? @event_dir_parts[0 .. $data_type_dir_name_idx]
                                                         : @event_dir_parts
                        );
                        my $event_dir_rel_to_base = File::Spec->abs2rel($event_dir, $base_dir);
                        my @event_dir_rel_to_base_parts = File::Spec->splitdir($event_dir_rel_to_base);
                        @event_dir_rel_to_base_parts = grep { $_ !~ /^$program_name/ } @event_dir_rel_to_base_parts;
                        my $data_type_dir_name_rel_to_base_idx = firstidx { exists $data_type_dir_names{$_} } @event_dir_rel_to_base_parts;
                        my $dataset_name = join(' ', 
                            $data_type_dir_name_rel_to_base_idx >= 0 ? @event_dir_rel_to_base_parts[0 .. $data_type_dir_name_rel_to_base_idx]
                                                                     : @event_dir_rel_to_base_parts
                        );
                        if ($event->path ne $dataset_dir) {
                            my $event_path_rel_to_dataset = File::Spec->abs2rel($event->path, $dataset_dir);
                            push @{$event_data_by_program_dataset{$program_name}{$dataset_name}{paths}}, $event_path_rel_to_dataset;
                        }
                        $event_data_by_program_dataset{$program_name}{$dataset_name}{new_events}++;
                        last;
                    }
                }
            }
        }
    }
    print Dumper(\%event_data_by_program_dataset) if $debug and %event_data_by_program_dataset;
    for my $program_name (keys %event_data_by_program_dataset) {
        for my $dataset_name (keys %{$event_data_by_program_dataset{$program_name}}) {
            if (!exists $event_data_by_program_dataset{$program_name}{$dataset_name}{new_events}) {
                print "[", scalar localtime, "] $program_name $dataset_name completed (", 
                      scalar(@{$event_data_by_program_dataset{$program_name}{$dataset_name}{paths}}), 
                      " events), sending email: ";
                my $email = Email::Simple->create(
                    header => [
                        From => $email_from_address,
                        To => join(',', @email_to_addresses),
                        Cc => join(',', @email_cc_addresses, @{$program_config{$program_name}{'email_cc_addresses'}}),
                        Subject => "New $program_name Uploads" . ($dataset_name ? ": $dataset_name" : ''),
                    ],
                    body => "The following data has recently been uploaded to $program_name" .
                            ($dataset_name ? " $dataset_name " : ' ' ) . ":\n\n" .
                            join("\n", @{$event_data_by_program_dataset{$program_name}{$dataset_name}{paths}}) . "\n",
                );
                if (try_to_sendmail($email)) {
                    print "success\n";
                    delete $event_data_by_program_dataset{$program_name}{$dataset_name};
                }
                else {
                    print "failure\n"; 
                }
            }
            else {
                print "[", scalar localtime, "] $program_name $dataset_name $event_data_by_program_dataset{$program_name}{$dataset_name}{new_events} new events\n";
                delete $event_data_by_program_dataset{$program_name}{$dataset_name}{new_events};
            }
        }
    }
    sleep $watcher_sleep_interval;
}
print "[", scalar localtime, "] Stopping watcher\n";
exit;

__END__

=head1 NAME 

watch_dcc_uploads - Watch OCG DCC Upload Directories

=head1 SYNOPSIS

 watch_dcc_uploads [options] <sleep interval>
 
 Parameters:
    <sleep interval>    Watcher sleep interval (in secconds)
 
 Options:
    --help              Display usage message and exit
    --version           Display program version and exit
    --debug             Debug mode
    
=cut


#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib/perl5";
use sigtrap qw( handler sig_handler normal-signals error-signals ALRM );
use File::Basename qw( fileparse );
use File::Path 2.11 qw( make_path remove_tree );
use Getopt::Long qw( :config auto_help auto_version );
use List::Util qw( any all first none uniq );
use NCI::OCGDCC::Utils qw( load_configs );
use Pod::Usage qw( pod2usage );
use Sort::Key::Natural qw( natsort );
use Term::ANSIColor;
use Data::Dumper;

sub sig_handler {
    die "Caught signal, exiting\n";
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
    cgi
    common
    data_util
));
my @program_names = @{$config_hashref->{'common'}->{'program_names'}};
my %program_project_names = %{$config_hashref->{'common'}->{'program_project_names'}};
my %program_project_names_w_subprojects = %{$config_hashref->{'common'}->{'program_project_names_w_subprojects'}};
my @programs_w_data_types = @{$config_hashref->{'common'}->{'programs_w_data_types'}};
my @data_types = @{$config_hashref->{'common'}->{'data_types'}};
my @data_types_w_data_levels = @{$config_hashref->{'common'}->{'data_types_w_data_levels'}};
my @data_level_dir_names = @{$config_hashref->{'common'}->{'data_level_dir_names'}};
my (
    $owner_name,
    $ctrld_dir_mode,
    $ctrld_dir_mode_str,
    $ctrld_file_mode,
    $ctrld_file_mode_str,
    $public_dir_mode,
    $public_dir_mode_str,
    $public_file_mode,
    $public_file_mode_str,
) = @{$config_hashref->{'common'}->{'data_filesys_info'}}{qw(
    adm_owner_name
    dn_ctrld_dir_mode
    dn_ctrld_dir_mode_str
    dn_ctrld_file_mode
    dn_ctrld_file_mode_str
    dn_public_dir_mode
    dn_public_dir_mode_str
    dn_public_file_mode
    dn_public_file_mode_str
)};
my $default_rsync_opts = $config_hashref->{'data_util'}->{'sync_dcc_data'}->{'default_rsync_opts'};
my %data_type_sync_config = %{$config_hashref->{'data_util'}->{'sync_dcc_data'}->{'data_type_sync_config'}};
my %program_dests = %{$config_hashref->{'data_util'}->{'sync_dcc_data'}->{'program_dests'}};
my @param_groups = qw(
    programs
    projects
    data_types
    data_sets
    data_level_dirs
    dests
);

# check data type sync config
for my $data_type (@data_types) {
    if (
        defined($data_type_sync_config{$data_type}) and
        defined($data_type_sync_config{$data_type}{'default'})
    ) {
        if (any { $data_type eq $_ } @data_types_w_data_levels) {
            for my $data_level_dir_name (@data_level_dir_names) {
                if (defined($data_type_sync_config{$data_type}{'default'}{$data_level_dir_name})) {
                    check_data_type_sync_config_node(
                        $data_type,
                        $data_type_sync_config{$data_type}{'default'}{$data_level_dir_name},
                    );
                }
            }
        }
        else {
            check_data_type_sync_config_node(
                $data_type,
                $data_type_sync_config{$data_type}{'default'},
            );
        }
    }
    else {
        die +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
            ": missing/invalid '$data_type' rsync include/exclude pattern config\n";
    }
    if (defined($data_type_sync_config{$data_type}{'custom'})) {
        for my $program_name (natsort keys %{$data_type_sync_config{$data_type}{'custom'}}) {
            if (any { $program_name eq $_ } @program_names) {
                for my $project_name (natsort keys %{$data_type_sync_config{$data_type}{'custom'}{$program_name}}) {
                    if (any { $project_name eq $_ } @{$program_project_names{$program_name}}) {
                        if (any { $data_type eq $_ } @data_types_w_data_levels) {
                            for my $data_level_dir_name (@data_level_dir_names) {
                                if (defined($data_type_sync_config{$data_type}{'custom'}{$program_name}{$project_name}{$data_level_dir_name})) {
                                    check_data_type_sync_config_node(
                                        $data_type,
                                        $data_type_sync_config{$data_type}{'custom'}{$program_name}{$project_name}{$data_level_dir_name},
                                    );
                                }
                            }
                        }
                        else {
                            check_data_type_sync_config_node(
                                $data_type,
                                $data_type_sync_config{$data_type}{'custom'}{$program_name}{$project_name},
                            );
                        }
                    }
                    else {
                        die +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                            ": invalid $data_type rsync include/exclude pattern custom config\n";
                    }
                }
            }
            else {
                die +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                    ": invalid $data_type rsync include/exclude pattern custom config\n";
            }
        }
    }
}

my $dry_run = 0;
my $delete = 0;
my $verbose = 0;
my $debug = 0;
GetOptions(
    'dry-run' => \$dry_run,
    'delete' => \$delete,
    'verbose' => \$verbose,
    'debug' => \$debug,
) || pod2usage(-verbose => 0);
if ($< != 0 and !$dry_run) {
    pod2usage(
        -message => 'Script must be run with sudo',
        -verbose => 0,
    );
}
my %user_params;
if (@ARGV) {
    for my $i (0 .. $#param_groups) {
        next unless defined $ARGV[$i] and $ARGV[$i] !~ /^\s*$/;
        my (@valid_user_params, @invalid_user_params, @valid_choices);
        my @user_params = split(',', $ARGV[$i]);
        if ($param_groups[$i] eq 'programs') {
            for my $program_name (@program_names) {
                push @valid_user_params, $program_name if any { m/^$program_name$/i } @user_params;
            }
            for my $user_param (@user_params) {
                push @invalid_user_params, $user_param if none { m/^$user_param$/i } @program_names;
            }
            @valid_choices = @program_names;
        }
        elsif ($param_groups[$i] eq 'projects') {
            my @program_projects = uniq(
                defined($user_params{programs})
                    ? map { @{$program_project_names{$_}} } @{$user_params{programs}}
                    : map { @{$program_project_names{$_}} } @program_names
            );
            for my $project_name (@program_projects) {
                push @valid_user_params, $project_name if any { m/^$project_name$/i } @user_params;
            }
            for my $user_param (@user_params) {
                push @invalid_user_params, $user_param if none { m/^$user_param$/i } @program_projects;
            }
            @valid_choices = @program_projects;
        }
        elsif ($param_groups[$i] eq 'data_types') {
            for my $user_param (@user_params) {
                $user_param = 'mRNA-seq' if $user_param =~ /^RNA-seq$/i;
            }
            for my $data_type (@data_types) {
                push @valid_user_params, $data_type if any { m/^$data_type$/i } @user_params;
            }
            for my $user_param (@user_params) {
                push @invalid_user_params, $user_param if none { m/^$user_param$/i } @data_types;
            }
            @valid_choices = @data_types;
        }
        elsif ($param_groups[$i] eq 'dests') {
            my @program_dests = uniq(
                defined($user_params{programs})
                    ? map { @{$program_dests{$_}} } grep { defined($program_dests{$_}) } @{$user_params{programs}}
                    : map { @{$program_dests{$_}} } grep { defined($program_dests{$_}) } @program_names
            );
            for my $dest (@program_dests) {
                push @valid_user_params, $dest if any { m/^$dest$/i } @user_params;
            }
            for my $user_param (@user_params) {
                push @invalid_user_params, $user_param if none { m/^$user_param$/i } @program_dests;
            }
            @valid_choices = @program_dests;
        }
        elsif ($param_groups[$i] eq 'data_level_dirs') {
            for my $data_level_dir_name (@data_level_dir_names) {
                push @valid_user_params, $data_level_dir_name if any { m/^$data_level_dir_name$/i } @user_params;
            }
            for my $user_param (@user_params) {
                push @invalid_user_params, $user_param if none { m/^$user_param$/i } @data_level_dir_names;
            }
            @valid_choices = @data_level_dir_names;
        }
        else {
            @valid_user_params = @user_params;
        }
        if (@invalid_user_params) {
            (my $type = $param_groups[$i]) =~ s/s$//;
            $type =~ s/_/ /g;
            pod2usage(
                -message =>
                    "Invalid $type" . ( scalar(@invalid_user_params) > 1 ? 's' : '' ) . ': ' .
                    join(', ', @invalid_user_params) . "\n" .
                    'Choose from: ' . join(', ', @valid_choices),
                -verbose => 0,
            );
        }
        $user_params{$param_groups[$i]} = \@valid_user_params;
    }
}

print STDERR "\%user_params:\n", Dumper(\%user_params) if $debug;
for my $program_name (@program_names) {
    next if defined $user_params{programs} and none { $program_name eq $_ } @{$user_params{programs}};
    # Release dest
    if (
        exists($user_params{dests}) and
        any { $_ eq 'Release' } @{$user_params{dests}}
    ) {
        $user_params{dests} = [];
        if ($program_name ne 'CTD2') {
            push @{$user_params{dests}}, qw( Controlled );
        }
        push @{$user_params{dests}}, qw(
            Public
            Release
        );
    }
    PROJECT_NAME: for my $project_name (@{$program_project_names{$program_name}}) {
        next if defined $user_params{projects} and none { $project_name eq $_ } @{$user_params{projects}};
        my ($disease_proj, $subproject);
        if (any { $project_name eq $_ } @{$program_project_names_w_subprojects{$program_name}}) {
            ($disease_proj, $subproject) = split /-/, $project_name, 2;
        }
        else {
            $disease_proj = $project_name;
        }
        my $project_dir_path_part = $disease_proj;
        if (defined($subproject)) {
            $project_dir_path_part = "$project_dir_path_part/$subproject";
        }
        # programs with data types
        if (any { $program_name eq $_ } @programs_w_data_types) {
            DATA_TYPE: for my $data_type (@data_types) {
                next if defined $user_params{data_types} and none { $data_type eq $_ } @{$user_params{data_types}};
                (my $data_type_dir_name = $data_type) =~ s/-Seq$/-seq/i;
                my $data_type_dir = "/local/ocg-dcc/data/\U$program_name\E/$project_dir_path_part/$data_type_dir_name";
                next unless -d $data_type_dir;
                opendir(my $data_type_dh, $data_type_dir)
                    or die +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'), ": could not open $data_type_dir: $!";
                my @data_type_sub_dir_names = grep { -d "$data_type_dir/$_" and !m/^\./ } readdir($data_type_dh);
                closedir($data_type_dh);
                my @datasets;
                if (all { m/^(current|old)$/ } @data_type_sub_dir_names) {
                    push @datasets, '';
                }
                elsif (none { m/^(current|old)$/ } @data_type_sub_dir_names) {
                    for my $data_type_sub_dir_name (@data_type_sub_dir_names) {
                        my $data_type_sub_dir = "$data_type_dir/$data_type_sub_dir_name";
                        opendir(my $data_type_sub_dh, $data_type_sub_dir)
                            or die +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'), ": could not open $data_type_sub_dir: $!";
                        my @sub_dir_names = grep { -d "$data_type_sub_dir/$_" and !m/^\./ } readdir($data_type_sub_dh);
                        closedir($data_type_sub_dh);
                        if (all { m/^(current|old)$/ } @sub_dir_names) {
                            push @datasets, $data_type_sub_dir_name;
                        }
                        else {
                            warn +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                                 ": $data_type_dir subdirectory structure is invalid\n";
                            next DATA_TYPE;
                        }
                    }
                }
                else {
                    warn +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                         ": $data_type_dir subdirectory structure is invalid\n";
                    next DATA_TYPE;
                }
                for my $dataset (@datasets) {
                    next if defined $user_params{data_sets} and none { $dataset eq $_ } @{$user_params{data_sets}};
                    my $dataset_dir = $data_type_dir . ( $dataset eq '' ? $dataset : "/$dataset" ) . '/current';
                    next unless -d $dataset_dir;
                    for my $dest (@{$program_dests{$program_name}}) {
                        next if (!defined $user_params{dests} and $dest ne 'PreRelease') or
                                ( defined $user_params{dests} and none { $dest eq $_ } @{$user_params{dests}});
                        my $download_dir_name = $dest;
                        if ($dest eq 'Controlled') {
                            if ($program_name eq 'CGCI' and $project_name eq 'MB') {
                                $download_dir_name = "${dest}_Pediatric";
                            }
                        }
                        elsif ($dest eq 'Release') {
                            $download_dir_name = 'PreRelease';
                        }
                        my $dest_data_type_dir = "/local/ocg-dcc/download/\U$program_name\E/$download_dir_name/$project_dir_path_part/$data_type_dir_name";
                        my $dest_dataset_dir = $dest_data_type_dir . ( $dataset ? "/$dataset" : '' );
                        my $group_name = $dest eq 'Controlled'
                                       ? (
                                            defined($config_hashref->{'common'}->{'data_filesys_info'}->{'program_project_dn_ctrld_group_name'}) and
                                            defined($config_hashref->{'common'}->{'data_filesys_info'}->{'program_project_dn_ctrld_group_name'}->{$program_name}) and
                                            defined($config_hashref->{'common'}->{'data_filesys_info'}->{'program_project_dn_ctrld_group_name'}->{$program_name}->{$project_name})
                                         ) ? $config_hashref->{'common'}->{'data_filesys_info'}->{'program_project_dn_ctrld_group_name'}->{$program_name}->{$project_name}
                                           : $config_hashref->{'common'}->{'data_filesys_info'}->{'program_dn_ctrld_group_name'}->{$program_name}
                                       : (
                                            defined($config_hashref->{'common'}->{'data_filesys_info'}->{'program_dn_group_name'}->{$program_name})
                                         ) ? $config_hashref->{'common'}->{'data_filesys_info'}->{'program_dn_group_name'}->{$program_name}
                                           : $config_hashref->{'common'}->{'data_filesys_info'}->{'dn_ro_group_name'};
                        # data types that have data levels (except for Resources datasets)
                        if (( any { $data_type eq $_ } @data_types_w_data_levels ) and $project_name ne 'Resources') {
                            for my $data_level_dir_name (@data_level_dir_names) {
                                next if defined($user_params{data_level_dirs}) and none { $data_level_dir_name eq $_ } @{$user_params{data_level_dirs}};
                                my $data_level_dir = "$dataset_dir/$data_level_dir_name";
                                next unless -d $data_level_dir;
                                my $dest_data_level_dir = "$dest_dataset_dir/$data_level_dir_name";
                                my $header = "[$program_name $project_name $data_type" . ( $dataset ? " $dataset" : '' ) . " $dest $data_level_dir_name]";
                                my $dest_data_type_sync_config_node_hashref;
                                if (
                                    defined($data_type_sync_config{$data_type}{'custom'}) and
                                    defined($data_type_sync_config{$data_type}{'custom'}{$program_name}) and
                                    defined($data_type_sync_config{$data_type}{'custom'}{$program_name}{$project_name}) and
                                    defined($data_type_sync_config{$data_type}{'custom'}{$program_name}{$project_name}{$data_level_dir_name})
                                ) {
                                    if (defined($data_type_sync_config{$data_type}{'custom'}{$program_name}{$project_name}{$data_level_dir_name}{lc($dest)})) {
                                        $dest_data_type_sync_config_node_hashref =
                                            $data_type_sync_config{$data_type}{'custom'}{$program_name}{$project_name}{$data_level_dir_name}{lc($dest)};
                                    }
                                }
                                elsif (
                                    defined($data_type_sync_config{$data_type}{'default'}) and
                                    defined($data_type_sync_config{$data_type}{'default'}{$data_level_dir_name}) and
                                    defined($data_type_sync_config{$data_type}{'default'}{$data_level_dir_name}{lc($dest)})
                                ) {
                                    $dest_data_type_sync_config_node_hashref = $data_type_sync_config{$data_type}{'default'}{$data_level_dir_name}{lc($dest)};
                                }
                                if (
                                    $dest ne 'Release' and
                                    (
                                        !defined($dest_data_type_sync_config_node_hashref) or
                                        !exists($dest_data_type_sync_config_node_hashref->{no_data})
                                    )
                                ) {
                                    print "$header\n";
                                    sync_to_dest(
                                        $dest,
                                        $data_level_dir,
                                        $dest_data_level_dir,
                                        $dest_data_type_sync_config_node_hashref,
                                        $group_name,
                                    );
                                    print "\n";
                                }
                                elsif (-e $dest_data_level_dir) {
                                    print "$header\n";
                                    if ($dest ne 'Release' or $delete) {
                                        clean_up_dest($dest_data_level_dir);
                                    }
                                    else {
                                        print "Keeping $dest_data_level_dir\n";
                                    }
                                    print "\n";
                                }
                            }
                        }
                        # data types that don't have data levels (and Resources datasets)
                        elsif (!defined $user_params{data_level_dirs}) {
                            my $header = "[$program_name $project_name $data_type" . ( $dataset ? " $dataset" : '' ) . " $dest]";
                            my $dest_data_type_sync_config_node_hashref;
                            if (
                                defined($data_type_sync_config{$data_type}{'custom'}) and
                                defined($data_type_sync_config{$data_type}{'custom'}{$program_name}) and
                                defined($data_type_sync_config{$data_type}{'custom'}{$program_name}{$project_name})
                            ) {
                                if (defined($data_type_sync_config{$data_type}{'custom'}{$program_name}{$project_name}{lc($dest)})) {
                                    $dest_data_type_sync_config_node_hashref = $data_type_sync_config{$data_type}{'custom'}{$program_name}{$project_name}{lc($dest)};
                                }
                            }
                            elsif (
                                defined($data_type_sync_config{$data_type}{'default'}) and
                                defined($data_type_sync_config{$data_type}{'default'}{lc($dest)})
                            ) {
                               $dest_data_type_sync_config_node_hashref = $data_type_sync_config{$data_type}{'default'}{lc($dest)};
                            }
                            if (
                                $dest ne 'Release' and
                                (
                                    !defined($dest_data_type_sync_config_node_hashref) or
                                    !exists($dest_data_type_sync_config_node_hashref->{no_data})
                                )
                            ) {
                                print "$header\n";
                                sync_to_dest(
                                    $dest,
                                    $dataset_dir,
                                    $dest_dataset_dir,
                                    $dest_data_type_sync_config_node_hashref,
                                    $group_name,
                                );
                                print "\n";
                            }
                            elsif (-e $dest_dataset_dir) {
                                print "$header\n";
                                if ($dest ne 'Release' or $delete) {
                                    clean_up_dest($dest_dataset_dir);
                                }
                                else {
                                    print "Keeping $dest_dataset_dir\n";
                                }
                                print "\n";
                            }
                        }
                        # clean up empty dest dirs (during Release or to clean up when nothing gets synced)
                        my $header = "[$program_name $project_name $data_type" . ( $dataset ? " $dataset" : '' ) . " $dest]";
                        my ($printed_header, $empty_dirs_exist);
                        for my $dest_dir ($dest_dataset_dir, $dest_data_type_dir) {
                            if (-d -z $dest_dir) {
                                if (( any { $data_type eq $_ } @data_types_w_data_levels ) and !$printed_header) {
                                    print "$header\n";
                                    $printed_header++;
                                }
                                clean_up_dest($dest_dir);
                                $empty_dirs_exist++;
                            }
                        }
                        print "\n" if $empty_dirs_exist;
                    }
                }
            }
        }
        # programs w/o data types
        else {
            my $project_dir = "/local/ocg-dcc/data/\U$program_name\E/$project_dir_path_part";
            next unless -d $project_dir;
            opendir(my $project_dh, $project_dir)
                or die +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'), ": could not open $project_dir: $!";
            my @project_sub_dir_names = grep { -d "$project_dir/$_" and !m/^\./ } readdir($project_dh);
            closedir($project_dh);
            my @datasets;
            if (all { m/^(current|old)$/ } @project_sub_dir_names) {
                push @datasets, '';
            }
            elsif (none { m/^(current|old)$/ } @project_sub_dir_names) {
                for my $project_sub_dir_name (@project_sub_dir_names) {
                    my $project_sub_dir = "$project_dir/$project_sub_dir_name";
                    opendir(my $project_sub_dh, $project_sub_dir)
                        or die +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                               ": could not open $project_sub_dir: $!";
                    my @sub_dir_names = grep { -d "$project_sub_dir/$_" and !m/^\./ } readdir($project_sub_dh);
                    closedir($project_sub_dh);
                    if (all { m/^(current|old)$/ } @sub_dir_names) {
                        push @datasets, $project_sub_dir_name;
                    }
                    else {
                        warn +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                             ": $project_dir subdirectory structure is invalid\n";
                        next PROJECT_NAME;
                    }
                }
            }
            else {
                warn +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                     ": $project_dir subdirectory structure is invalid\n";
                next PROJECT_NAME;
            }
            for my $dataset (@datasets) {
                next if defined($user_params{data_sets}) and none { $dataset eq $_ } @{$user_params{data_sets}};
                my $dataset_dir = $project_dir . ( $dataset eq '' ? $dataset : "/$dataset" ) . '/current';
                next unless -d $dataset_dir;
                for my $dest (@{$program_dests{$program_name}}) {
                    next if (!defined $user_params{dests} and none { $dest eq $_ } qw( PreRelease Network )) or
                            ( defined $user_params{dests} and none { $dest eq $_ } @{$user_params{dests}});
                    my $download_dir_name = $dest;
                    if ($dest eq 'Release') {
                        $download_dir_name = $program_name ne 'CTD2'
                                           ? 'PreRelease'
                                           : 'Network';
                    }
                    my $dest_project_dir = "/local/ocg-dcc/download/\U$program_name\E/$download_dir_name/$project_dir_path_part";
                    my $dest_dataset_dir = $dest_project_dir . ( $dataset ? "/$dataset" : '' );
                     my $group_name = $dest eq 'Controlled'
                                    ? (
                                         defined($config_hashref->{'common'}->{'data_filesys_info'}->{'program_project_dn_ctrld_group_name'}) and
                                         defined($config_hashref->{'common'}->{'data_filesys_info'}->{'program_project_dn_ctrld_group_name'}->{$program_name}) and
                                         defined($config_hashref->{'common'}->{'data_filesys_info'}->{'program_project_dn_ctrld_group_name'}->{$program_name}->{$project_name})
                                      ) ? $config_hashref->{'common'}->{'data_filesys_info'}->{'program_project_dn_ctrld_group_name'}->{$program_name}->{$project_name}
                                        : $config_hashref->{'common'}->{'data_filesys_info'}->{'program_dn_ctrld_group_name'}->{$program_name}
                                    : (
                                        defined($config_hashref->{'common'}->{'data_filesys_info'}->{'program_dn_group_name'}->{$program_name})
                                      ) ? $config_hashref->{'common'}->{'data_filesys_info'}->{'program_dn_group_name'}->{$program_name}
                                        : $config_hashref->{'common'}->{'data_filesys_info'}->{'dn_ro_group_name'};
                    my $header = "[$program_name $project_name" . ( $dataset ? " $dataset" : '' ) . " $dest]";
                    my $dest_data_type_sync_config_node_hashref;
                    if ($dest ne 'Release') {
                        print "$header\n";
                        sync_to_dest(
                            $dest,
                            $dataset_dir,
                            $dest_dataset_dir,
                            $dest_data_type_sync_config_node_hashref,
                            $group_name,
                        );
                        print "\n";
                    }
                    elsif (-e $dest_dataset_dir) {
                        print "$header\n";
                        if ($dest ne 'Release' or $delete) {
                            clean_up_dest($dest_dataset_dir);
                        }
                        else {
                            print "Keeping $dest_dataset_dir\n";
                        }
                        print "\n";
                    }
                    # clean up empty dest dirs (during Release or to clean up when nothing gets synced)
                    # programs w/o data types always keep project dir
                    my ($printed_header, $empty_dirs_exist);
                    for my $dest_dir ($dest_dataset_dir) {
                        if (-d -z $dest_dir) {
                            if (!$printed_header) {
                                print "$header\n";
                                $printed_header++;
                            }
                            clean_up_dest($dest_dir);
                            $empty_dirs_exist++;
                        }
                    }
                    print "\n" if $empty_dirs_exist;
                }
            }
        }
    }
}
exit;

sub check_data_type_sync_config_node {
    my (
        $data_type,
        $config_section_hashref,
    ) = @_;
    my @dests = natsort uniq(map { @{$program_dests{$_}} } grep { defined($program_dests{$_}) } @programs_w_data_types);
    for my $dest (map(lc, @dests)) {
        if (defined($config_section_hashref->{$dest})) {
            if (defined($config_section_hashref->{$dest}->{excludes})) {
                for my $type (qw( excludes includes )) {
                    if (
                        defined($config_section_hashref->{$dest}->{$type}) and
                        ref($config_section_hashref->{$dest}->{$type}) ne 'ARRAY'
                    ) {
                        die +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                            ": invalid $data_type $dest $type rsync pattern config\n";
                    }
                }
            }
        }
    }
}

sub sync_to_dest {
    my (
        $dest,
        $src_dir,
        $dest_dir,
        $dest_data_type_sync_config_node_hashref,
        $group_name,
    ) = @_;
    my (
        $dir_mode, $dir_mode_str,
        $file_mode, $file_mode_str,
    );
    # Controlled
    if ($dest eq 'Controlled') {
        $dir_mode = $ctrld_dir_mode;
        $dir_mode_str = $ctrld_dir_mode_str;
        $file_mode = $ctrld_file_mode;
        $file_mode_str = $ctrld_file_mode_str;
    }
    # Public
    elsif ($dest eq 'Public') {
        $dir_mode = $public_dir_mode;
        $dir_mode_str = $public_dir_mode_str;
        $file_mode = $public_file_mode;
        $file_mode_str = $public_file_mode_str;
    }
    # PreRelease, Network, BCCA, Germline
    else {
        $dir_mode = $ctrld_dir_mode;
        $dir_mode_str = $ctrld_dir_mode_str;
        $file_mode = $ctrld_file_mode;
        $file_mode_str = $ctrld_file_mode_str;
    }
    # create/set up dest dir if needed
    if (-l $src_dir and $dest eq 'PreRelease') {
        if (-e $dest_dir) {
            if (!-l $dest_dir) {
                print "Deleting $dest_dir\n";
                if (!$dry_run) {
                    remove_tree($dest_dir, {
                        verbose => $verbose,
                        error => \my $err,
                    });
                    if (@{$err}) {
                        for my $diag (@{$err}) {
                            my ($file, $message) = %{$diag};
                            warn +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                                 ": could not delete $file: $message\n";
                        }
                        return;
                    }
                }
            }
            elsif (readlink($src_dir) ne readlink($dest_dir)) {
                print "Removing symlink $dest_dir\n";
                if (!$dry_run) {
                    if (!unlink($dest_dir)) {
                        warn +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                             ": could not unlink $dest_dir: $!\n";
                        return;
                    }
                }
            }
        }
        if (!-e $dest_dir) {
            print "Creating symlink $dest_dir\n";
            if (!$dry_run) {
                my $dest_parent_dir = (fileparse($dest_dir))[1];
                if (!-d $dest_parent_dir) {
                    make_path($dest_parent_dir, {
                        chmod => $dir_mode,
                        owner => $owner_name,
                        group => $group_name,
                        error => \my $err,
                    });
                    if (@{$err}) {
                        for my $diag (@{$err}) {
                            my ($file, $message) = %{$diag};
                            warn +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                                 ": could not create $file: $message\n";
                        }
                        return;
                    }
                }
                if (!symlink(readlink($src_dir), $dest_dir)) {
                    warn +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                    ": could not create link $dest_dir: $!\n";
                    return;
                }
            }
        }
    }
    elsif (!-d $dest_dir) {
        print "Creating $dest_dir\n";
        if (!$dry_run) {
            make_path($dest_dir, {
                chmod => $dir_mode,
                owner => $owner_name,
                group => $group_name,
                error => \my $err,
            });
            if (@{$err}) {
                for my $diag (@{$err}) {
                    my ($file, $message) = %{$diag};
                    warn +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                         ": could not create $file: $message\n";
                }
                return;
            }
        }
    }
    my $rsync_incl_excl_str = '';
    if (
        any { $dest eq $_ } qw( PreRelease Controlled Public ) and
        defined($dest_data_type_sync_config_node_hashref)
    ) {
        # includes (always before excludes)
        if (defined($dest_data_type_sync_config_node_hashref->{includes})) {
            $rsync_incl_excl_str .= ' ' if $rsync_incl_excl_str;
            $rsync_incl_excl_str .= join(' ',
                map { "--include=\"$_\"" } @{$dest_data_type_sync_config_node_hashref->{includes}}
            );
        }
        # excludes
        if (defined($dest_data_type_sync_config_node_hashref->{excludes})) {
            $rsync_incl_excl_str .= ' ' if $rsync_incl_excl_str;
            $rsync_incl_excl_str .= join(' ',
                map { "--exclude=\"$_\"" } @{$dest_data_type_sync_config_node_hashref->{excludes}}
            );
        }
    }
    my @rsync_opts = ( $default_rsync_opts );
    push @rsync_opts, (
        defined($dest_data_type_sync_config_node_hashref) and
        $dest_data_type_sync_config_node_hashref->{copy_links}
    ) ? '--copy-links' : '--links';
    push @rsync_opts, '--dry-run' if $dry_run;
    push @rsync_opts, '--delete' if $delete;
    if (
        defined($dest_data_type_sync_config_node_hashref->{excludes}) and
        !$dest_data_type_sync_config_node_hashref->{no_delete_excluded}
    ) {
        push @rsync_opts, '--delete-excluded';
    }
    my $rsync_opts_str = join(' ', @rsync_opts);
    # make sure rsync src and dest paths always finish with /
    my $rsync_cmd_str      = "rsync $rsync_opts_str $rsync_incl_excl_str \"$src_dir/\" \"$dest_dir/\"";
    my $rmdir_cmd_str      = "find $dest_dir -depth -type d -empty -exec rmdir -v {} \\;";
    my $dir_chmod_cmd_str  = "find $dest_dir -type d -exec chmod $dir_mode_str {} \\;";
    my $file_chmod_cmd_str = "find $dest_dir -type f -exec chmod $file_mode_str {} \\;";
    my $chown_cmd_str      = "chown -Rh $owner_name:$group_name $dest_dir";
    for my $cmd_str ($rsync_cmd_str, $rmdir_cmd_str, $dir_chmod_cmd_str, $file_chmod_cmd_str, $chown_cmd_str) {
        next if (
            $cmd_str eq $dir_chmod_cmd_str or
            $cmd_str eq $file_chmod_cmd_str or
            $cmd_str eq $chown_cmd_str
        ) and !-d $dest_dir;
        $cmd_str =~ s/\s+/ /g;
        if (($cmd_str eq $rsync_cmd_str) or !$dry_run) {
            print "$cmd_str\n";
            system($cmd_str) == 0
                or die +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                       ": command failed, exit code: ", $? >> 8, "\n";
        }
    }
}

sub clean_up_dest {
    my ($dest_dir) = @_;
    if (-l $dest_dir or -f $dest_dir) {
        print "Removing $dest_dir\n";
        if (!$dry_run) {
            unlink($dest_dir) or
                warn +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                     ": could not unlink $dest_dir: $!\n";
        }
    }
    elsif (-d $dest_dir) {
        print "Deleting $dest_dir\n";
        if (!$dry_run) {
            remove_tree($dest_dir, {
                verbose => $verbose,
                error => \my $err,
            });
            if (@{$err}) {
                for my $diag (@{$err}) {
                    my ($file, $message) = %{$diag};
                    warn +(-t STDERR ? colored('ERROR', 'red') : 'ERROR'),
                         ": could not delete $file: $message\n";
                }
            }
        }
    }
}

__END__

=head1 NAME

sync_dcc_data - OCG DCC Master Data-to-Download Areas Synchronizer

=head1 SYNOPSIS

 sync_dcc_data.pl <program name(s)> <project name(s)> <data type(s)> <data set(s)> <data level dir(s)> <destination(s)> [options]
 
 Parameters:
    <program name(s)>       Comma-separated list of program name(s) (optional, default: all programs)
    <project name(s)>       Comma-separated list of project name(s) (optional, default: all program projects)
    <data type(s)>          Comma-separated list of data type(s) (optional, default: all project data types)
    <data set(s)>           Comma-separated list of data set(s) (optional, default: all data type data sets)
    <data level dir(s)>     Comma-separated list of data level dir(s) (optional, default: all data set data level dirs)
    <destination(s)>        Comma-separated list of destination(s): PreRelease/Network, Controlled, Public, Release, Germline, BCCA (optional, default: PreRelease/Network)
 
 Options:
    --dry-run               Perform trial run with no changes made (sudo not required, default: off)
    --delete                Delete extraneous files from destination dirs (default: off)
    --verbose               Be verbose
    --help                  Display usage message and exit
    --version               Display program version and exit
 
=cut

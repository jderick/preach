#!/usr/intel/bin/perl
#
#  Given a preach log file on stdin, this script looks for an error
#  trace in the log file.  if it finds one, it prints the error trace
#  on stdout, but with differences between successive states indicated
#  by prefixing the line with DIFF> .  Example usage:
#
#  trace_diff_annotate.pl < my_model.log > my_model.error
#
#

my ($pre_trace,$start_state,$white_space,$next_state) = (1,2,3,4);
my $fsm = $pre_trace;
my @state_vars;
my %old_state;
my %new_state;
while (<>) {
  if ($fsm == $pre_trace) {
    if (/^Here's the first state/) {
      print;
      $fsm = $start_state;
    }
  } elsif ($fsm == $start_state) {
    print;
    if (/^(.*):(.*)$/) {
      my ($state_var,$value) = ($1,$2);
      @state_vars = (@state_vars,$state_var);
      $old_state{$state_var} = $value;
    } else {
      $fsm = $white_space;
    }
  } elsif ($fsm == $white_space) {
    print;
    $fsm = $next_state if /^Rule/;
  } else { # $fsm == $next_state
    if (/^(.*):(.*)$/) {
      my ($state_var,$value) = ($1,$2);
      $new_state{$state_var} = $value;
    } else {
      print_new_state();
      $fsm = $white_space;
    }
  }
}

sub print_new_state() 
{
  foreach my $var (@state_vars) {
    if ($old_state{$var} ne $new_state{$var}) {
      print "DIFF> ";
    }
    print "$var:$new_state{$var}\n";
    $old_state{$var} = $new_state{$var};
  }
}




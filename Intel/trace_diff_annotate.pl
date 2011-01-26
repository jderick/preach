#!/usr/intel/bin/perl
#
#  Given a preach log file on stdin, this script looks for an error
#  trace in the log file.  if it finds one, it prints the error trace
#  on stdout, but with differences between successive states indicated
#  by prefixing the line with DIFF> .  Example usage:
#
#  trace_diff_annotate.pl < my_model.log > my_model.error
#
#  Also, adding the flag -d will make it *only* print the diffs,
#  just like Murphi's -td flag.
#  Also, the ith Rule name in the error trace is prefixed with the 
#  number i in the output.
#

my $diff_only = (shift eq '-d');
my ($pre_trace,$pre_start_state,$start_state,$white_space,$next_state) = (1,2,3,4,5);
my $fsm = $pre_trace;
my @state_vars;
my %old_state;
my %new_state;
my $rule_counter = 0;
while (<>) {
  if ($fsm == $pre_trace) {
    if (/Found \(global\) deadlock/) { print; $fsm = $pre_start_state;}
    if (/Found Invariant Failure/) { print; $fsm = $pre_start_state;}
    if (/Found a CGT violation/) { print; $fsm = $pre_start_state;}
   
    if (/Murphi Engine threw an error/) { 
      print; <>; print;  # error msg shows up on following line
      $fsm = $pre_start_state;
    }
  } elsif ($fsm == $pre_start_state) {
    if (/Here's the first state/) {
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
    if (/^Rule/) {
       $fsm = $next_state; 
       print ++$rule_count.' ';
    }
    print;
    $fsm = $next_state if /Here's the CGT suffix/;
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
    if ($diff_only) {
      if ($old_state{$var} ne $new_state{$var}) {
        print "$var:$new_state{$var}\n";
      }
    } else {
      if ($old_state{$var} ne $new_state{$var}) {
        print "DIFF> ";
      }
      print "$var:$new_state{$var}\n";
    }
    $old_state{$var} = $new_state{$var};
  }
}




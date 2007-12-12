#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT::DSHCore;

use locale;

use Socket;

use xCAT::MsgUtils;
use xCAT::Utils;

#---------------------------------------------------------------------------

=head3
        fork_no_output

        Forks a process for the given command array and returns the process
        ID for the forked process.  Since no I/O is needed for the pipes, no
        STDOUT/STDERR pipes are returned to the caller.

        Arguments:
        	$fork_id - unique identifer to use for tracking the forked process
        	@command - command and parameter array to execute in the forkec process

        Returns:
        	$pid - process identifer for the forked process
                
        Globals:
        	None
    
        Error:
        	None
    
        Example:
        	$pid = xCAT::DSHCore->fork_no_output('hostname1PID', @command_array);

        Comments:

=cut

#---------------------------------------------------------------------------

sub fork_no_output
{
    my ($class, $fork_id, @command) = @_;

    my $pid;

    if ($pid = fork)
    {

    }
    elsif (defined $pid)
    {
        open(STDOUT, ">/dev/null");
        open(STDERR, ">/dev/null");

        select(STDOUT);
        $| = 1;
        select(STDERR);
        $| = 1;

        if (!(exec {$command[0]} @command))
        {
            return (-4, undef);
        }

    }
    else
    {
        return (-3, undef);
    }

    return ($pid, undef, undef, undef, undef);
}

#---------------------------------------------------------------------------

=head3
        fork_output

        Forks a process for the given command array and returns the process
        ID for the forked process and references to all I/O pipes for STDOUT
        and STDERR.

        Arguments:
        	$fork_id - unique identifer to use for tracking the forked process
        	@command - command and parameter array to execute in the forkec process

        Returns:
        	$pid - process identifer for the forked process
                
        Globals:
        	None
    
        Error:
        	None
    
        Example:
        	$pid = xCAT::DSHCore->fork_no_output('hostname1PID', @command_array);

        Comments:

=cut

#---------------------------------------------------------------------------

sub fork_output
{
    my ($class, $fork_id, @command) = @_;

    my $pid;
    my %pipes = ();

    my $rout_fh = "rout_$fork_id";
    my $rerr_fh = "rerr_$fork_id";
    my $wout_fh = "wout_$fork_id";
    my $werr_fh = "werr_$fork_id";

    (pipe($rout_fh, $wout_fh) == -1) && return (-1, undef);
    (pipe($rerr_fh, $werr_fh) == -1) && return (-2, undef);

    if ($pid = fork)
    {
        close($wout_fh);
        close($werr_fh);
    }

    elsif (defined $pid)
    {
        close($rout_fh);
        close($rerr_fh);

        !(open(STDOUT, ">&$wout_fh")) && return (-5, undef);
        !(open(STDERR, ">&$werr_fh")) && return (-6, undef);

        select(STDOUT);
        $| = 1;
        select(STDERR);
        $| = 1;

        if (!(exec {$command[0]} @command))
        {
            return (-4, undef);
        }

    }
    else
    {
        return (-3, undef);
    }

    return ($pid, *$rout_fh, *$rerr_fh, *$wout_fh, *$werr_fh);
}

#---------------------------------------------------------------------------

=head3
        ifconfig_inet

        Builds a list of all IP Addresses bound to the local host and
        stores them in a global list

        Arguments:
        	None

        Returns:
        	None
                
        Globals:
        	@local_inet
    
        Error:
        	None
    
        Example:
        	xCAT::DSHCore->ifconfig_inet;

        Comments:
        	Internal routine only

=cut

#---------------------------------------------------------------------------

sub ifconfig_inet
{
    @local_inet = ();

    if ($^O eq 'aix')
    {
        my @ip_address = ();
        my @output     = `/usr/sbin/ifconfig -a`;

        foreach $line (@output)
        {
            ($line =~ /inet ((\d{1,3}?\.){3}(\d){1,3})\s/o)
              && (push @local_inet, $1);
        }
    }

    elsif ($^O eq 'linux')
    {
        my @ip_address = ();
        my @output     = `/sbin/ifconfig -a`;

        foreach $line (@output)
        {
            ($line =~ /inet addr:((\d{1,3}?\.){3}(\d){1,3})\s/o)
              && (push @local_inet, $1);
        }
    }
}

#---------------------------------------------------------------------------

=head3
        pipe_handler

        Handles and processes dsh output from a given read pipe handle.  The output
        is immediately written to each output file handle as it is available.

        Arguments:
	        $options - options hash table describing dsh configuration options
	        $target_properties - property information of the target related to the pipe handle
	        $read_fh - reference to the read pipe handle
	        $buffer_size - local buffer size to read data from the handle
	        $label - prefix label to use for dsh output
	        $write_buffer - buffer of data that is yet to be written (must wait until \n is read)
	        @write_fhs - array of output file handles where output will be written

        Returns:
        	1 if the EOF reached on $read_fh
        	undef otherwise
                
        Globals:
        	None
    
        Error:
        	None
    
        Example:

        Comments:

=cut

#---------------------------------------------------------------------------

sub pipe_handler
{
    my ($class, $options, $target_properties, $read_fh, $buffer_size, $label,
        $write_buffer, @write_fhs)
      = @_;

    my $line;
    my $target_hostname;
    my $eof_reached = undef;

    while (sysread($read_fh, $line, $buffer_size) != 0
           || ($eof_reached = 1))
    {
        last if ($eof_reached);

        if ($line =~ /^\n$/)
        {

            # need to preserve blank lines in the output.
            $line = $label . $line;
        }

        my @lines = split "\n", $line;

        if (@$write_buffer)
        {
            my $buffered_line = shift @$write_buffer;
            my $next_line     = shift @lines;
            $next_line = $buffered_line . $next_line;
            unshift @lines, $next_line;
        }

        if ($line !~ /\n$/)
        {
            push @$write_buffer, (pop @lines);
        }

        if (@lines)
        {

            $line = join "\n", @lines;
            $line .= "\n";

            if ($line =~ /:DSH_TARGET_RC=/)
            {
                my $start_offset = index($line, ':DSH_TARGET_RC');
                my $end_offset = index($line, ':', $start_offset + 1);
                my $target_rc_string =
                  substr($line, $start_offset, $end_offset - $start_offset);
                my ($discard, $target_rc) = split '=', $target_rc_string;
                $line =~ s/:DSH_TARGET_RC=$target_rc:\n//g;
                $$target_properties{'target-rc'} = $target_rc;
            }

            if ($line ne '')
            {
                if ($line !~ /^$label\n$/)
                {
                    $line = $label . $line;
                }
                $line =~ s/$/\n/ if $line !~ /\n$/;
            }

            $line =~ s/\n/\n$label/g;
            ($line =~ /\n$label$/) && ($line =~ s/\n$label$/\n/);

            my @output_files    = ();
            my @output_file_nos = ();

            foreach $write_fh (@write_fhs)
            {
                my $file_no = fileno($write_fh);
                if (grep /$file_no/, @output_file_nos)
                {
                    $line =~ s/$label//g;
                }

                print $write_fh $line;
            }

            if (@output_files)
            {
                foreach $output_file (@output_files)
                {
                    pop @write_fhs;
                    close $output_file
                      || print STDOUT
                      "dsh>  Error_file_closed $$target_properties{hostname} $output_file\n";
                    my %rsp;
                    $rsp->{data}->[0] =
                      "Error_file_closed $$target_properties{hostname $output_file}.\n";
                    xCAT::MsgUtils->message("E", $rsp, $::CALLBACK);
                    ($output_file == $$target_properties{'output-fh'})
                      && delete $$target_properties{'output-fh'};
                    ($output_file == $$target_properties{'output-fh'})
                      && delete $$target_properties{'error-fh'};
                }
            }

            my $rin = '';
            vec($rin, fileno($read_fh), 1) = 1;
            my $fh_count = select($rin, undef, undef, 0);
            last if ($fh_count == 0);
        }
    }

    return $eof_reached;
}

#---------------------------------------------------------------------------

=head3
        pipe_handler_buffer

        Handles and processes dsh output from a given read pipe handle.  The output
        is stored in a buffer supplied by the caller.

        Arguments:
	        $target_properties - property information of the target related to the pipe handle
	        $read_fh - reference to the read pipe handle
	        $buffer_size - local buffer size to read data from the handle
	        $label - prefix label to use for dsh output
	        $write_buffer - buffer of data that is yet to be written (must wait until \n is read)
	        $output_buffer - buffer where output will be written

        Returns:
        	1 if the EOF reached on $read_fh
        	undef otherwise
                
        Globals:
        	None
    
        Error:
        	None
    
        Example:

        Comments:

=cut

#---------------------------------------------------------------------------

sub pipe_handler_buffer
{
    my ($class, $target_properties, $read_fh, $buffer_size, $label,
        $write_buffer, $output_buffer)
      = @_;

    my $line;
    my $eof_reached = undef;

    while (   (sysread($read_fh, $line, $buffer_size) != 0)
           || ($eof_reached = 1))
    {
        last if ($eof_reached);

        if ($line =~ /^\n$/)
        {

            # need to preserve blank lines in the output.
            $line = $label . $line;
        }

        my @lines = split "\n", $line;

        if (@$write_buffer)
        {
            my $buffered_line = shift @$write_buffer;
            my $next_line     = shift @lines;
            $next_line = $buffered_line . $next_line;
            unshift @lines, $next_line;
        }

        if ($line !~ /\n$/)
        {
            push @$write_buffer, (pop @lines);
        }

        if (@lines)
        {

            $line = join "\n", @lines;
            $line .= "\n";

            if ($line =~ /:DSH_TARGET_RC=/)
            {
                my $start_offset = index($line, ':DSH_TARGET_RC');
                my $end_offset = index($line, ':', $start_offset + 1);
                my $target_rc_string =
                  substr($line, $start_offset, $end_offset - $start_offset);
                my ($discard, $target_rc) = split '=', $target_rc_string;
                $line =~ s/:DSH_TARGET_RC=$target_rc:\n//g;
                $$target_properties{'target-rc'} = $target_rc;
            }

            if ($line ne '')
            {
                if ($line !~ /^$label\n$/)
                {
                    $line = $label . $line;
                }
                $line =~ s/$/\n/ if $line !~ /\n$/;
            }

            $line =~ s/\n/\n$label/g;
            ($line =~ /\n$label$/) && ($line =~ s/\n$label$/\n/);

            push @$output_buffer, $line;

            my $rin = '';
            vec($rin, fileno($read_fh), 1) = 1;
            my $fh_count = select($rin, undef, undef, 0);
            last if ($fh_count == 0);
        }
    }

    return $eof_reached;
}

#---------------------------------------------------------------------------

=head3
        fping_hostnames

        Executes fping on a given list of hostnames and returns a list of those
        hostnames that did not respond

        Arguments:
        	@hostnames - list of hostnames to execute for fping

        Returns:
        	@no_response - list of hostnames that did not respond
        	undef if fping is not installed
                
        Globals:
        	None
    
        Error:
        	None
    
        Example:
        	@bad_hosts = xCAT::DSHCore->fping_hostnames(@host_list);

        Comments:

=cut

#---------------------------------------------------------------------------

sub fping_hostnames
{
    my ($class, @hostnames) = @_;

    my $fping = (-x '/usr/sbin/fping') || undef;
    !$fping && return undef;

    my @output = `/usr/sbin/fping -B 1.0 -r 1 -t 50 -i 10 -p 50 @hostnames`;

    my @no_response = ();
    foreach $line (@output)
    {
        my ($hostname, $token, $status) = split ' ', $line;
        !(($token eq 'is') && ($status eq 'alive'))
          && (push @no_response, $hostname);
    }

    return @no_response;
}

#---------------------------------------------------------------------------

=head3
        ping_hostnames

        Executes ping on a given list of hostnames and returns a list of those
        hostnames that did not respond

        Arguments:
        	@hostnames - list of hostnames to execute for fping

        Returns:
        	@no_response - list of hostnames that did not respond
        	undef if fping is not installed
                
        Globals:
        	None
    
        Error:
        	None
    
        Example:
        	@bad_hosts = xCAT::DSHCore->ping_hostnames(@host_list);

        Comments:

=cut

#---------------------------------------------------------------------------

sub ping_hostnames
{
    my ($class, @hostnames) = @_;

    my $ping = (($^O eq 'aix') && '/usr/sbin/ping')
      || (($^O eq 'linux') && '/bin/ping')
      || undef;
    !$ping && return undef;

    my @no_response = ();
    foreach $hostname (@hostnames)
    {
        (system("$ping -c 1 -w 1 $hostname > /dev/null 2>&1") != 0)
          && (push @no_response, $hostname);
    }

    return @no_response;
}

#---------------------------------------------------------------------------

=head3
        resolve_hostnames

        Resolve all related information for a given target, including context
        IP address information and fully qualified hostname.  If the target is
        unresolvable include in a list of unresolvable targets, otherwise store
        all resolved properties for the target.

        Arguments:
        	$options - options hash table describing dsh configuration options
        	$resolved_targets - hash table of resolved properties, keyed by target name
        	$unresolved_targets - hash table of unresolved targets and relevant property information
        	$context_targets - hash table of targets grouped by context name
        	@target_list - input list of target names to resolve

        Returns:
        	None
                
        Globals:
        	None
    
        Error:
        	None
    
        Example:

        Comments:

=cut

#---------------------------------------------------------------------------

sub resolve_hostnames
{
    my ($class, $options, $resolved_targets, $unresolved_targets,
        $context_targets, @target_list)
      = @_;

    scalar(@local_inet) || xCAT::DSHCore->ifconfig_inet;

    foreach $context_user_target (@target_list)
    {
        my ($context, $user_target) = split ':', $context_user_target;
        if (($context eq 'XCAT') && ($$options{'context'} eq 'DSH'))
        {

            # The XCAT context may not be specified for this node since DSH is the only
            # available context.
            my %rsp;
            $rsp->{data}->[0] = "DSH is the only available context.\n";
            xCAT::MsgUtils->message("I", $rsp, $::CALLBACK);
            next;
        }
        !$user_target
          && (   ($user_target = $context)
              && ($context = $$options{'context'}));

        my ($user, $target) = split '@', $user_target;
        !$target && (($target = $user) && ($user = undef));

        $$options{'context-all'} && ($context = $$options{'context-all'});

        if (my ($hostname, $aliases, $addrtype, $length, @addrs) =
            gethostbyname($target))
        {
            my $ip_address = inet_ntoa($addrs[0]);
            my $localhost  = (grep { /^$ip_address$/ } @local_inet) || undef;

            if ($hostname eq $ip_address)
            {
                my $packed_ip = inet_aton($ip_address);
                my $hostbyaddr = gethostbyaddr($packed_ip, AF_INET);
                $hostbyaddr && ($hostname = $hostbyaddr);
            }

            my %properties = (
                              'hostname'   => $hostname,
                              'ip-address' => $ip_address,
                              'localhost'  => $localhost,
                              'user'       => $user,
                              'context'    => $context,
                              'unresolved' => $target
                              );

            $user && ($user .= '@');
            $$resolved_targets{"$user$hostname"} = \%properties;

            if ($context_targets)
            {
                if (!$$context_targets{$context})
                {
                    my %context_target_list = ();
                    $$context_targets{$context} = \%context_target_list;
                }

                $$context_targets{$context}{"$user$hostname"}++;
            }
        }

        else
        {
            my %properties = (
                              'hostname'   => $target,
                              'user'       => $user,
                              'context'    => $context,
                              'unresolved' => $target
                              );
            $$unresolved_targets{"$user_target"} = \%properties;
        }
    }

    xCAT::DSHCore->removeExclude($resolved_targets, $unresolved_targets,
                           $context_targets);
}

#---------------------------------------------------------------------------

=head3
        dping_hostnames

        Executes dping on a given list of hostnames and returns a list of those
        hostnames that did not respond

        Arguments:
                @hostnames - list of hostnames to execute for fping

	        Returns:
                @no_response - list of hostnames that did not respond

        Globals:
                None

        Error:
                None

        Example:
                @bad_hosts = xCAT::DSHCore->dping_hostnames(@host_list);

        Comments:

=cut

#---------------------------------------------------------------------------

sub dping_hostnames
{
    my ($class, @hostnames) = @_;

    my $hostname_list = join ",", @hostnames;
    my @output =
      xCAT::Utils->runcmd("/opt/csm/bin/dping -H $hostname_list", -1);

    my @no_response = ();
    foreach $line (@output)
    {
        my ($hostname, $result) = split ':', $line;
        my ($token,    $status) = split ' ', $result;
        chomp($token);
        !(($token eq 'ping') && ($status eq '(alive)'))
          && (push @no_response, $hostname);
    }

    return @no_response;
}

#---------------------------------------------------------------------------

sub removeExclude
{
    shift;
    my ($resolved_targets, $unresolved_targets, $context_targets) = @_;
    return if (!$resolved_targets || !$unresolved_targets);

    my @invalid_resolved_targets;
    my @invalid_unresolved_targets;

    %::__EXCLUDED_TARGETS;

    for my $unrsvl_tg (keys %$unresolved_targets)
    {
        if ($unresolved_targets->{$unrsvl_tg}->{'hostname'} =~ /^-/)
        {
            $::__EXCLUDED_TARGETS{$unrsvl_tg} =
              $unresolved_targets->{$unrsvl_tg};
            delete $unresolved_targets->{$unrsvl_tg};
        }
    }

    for my $excluded_tg (keys %::__EXCLUDED_TARGETS)
    {
        for my $rslv_tg (keys %$resolved_targets)
        {
            if (  $::__EXCLUDED_TARGETS{$excluded_tg}->{'hostname'} eq '-'
                . $resolved_targets->{$rslv_tg}->{'hostname'}
                || $::__EXCLUDED_TARGETS{$excluded_tg}->{'hostname'} eq '-'
                . $resolved_targets->{$rslv_tg}->{'ip-address'}
                || $::__EXCLUDED_TARGETS{$excluded_tg}->{'hostname'} eq '-'
                . $resolved_targets->{$rslv_tg}->{'unresolved'}
                || $::__EXCLUDED_TARGETS{$excluded_tg}->{'unresolved'} eq '-'
                . $resolved_targets->{$rslv_tg}->{'hostname'}
                || $::__EXCLUDED_TARGETS{$excluded_tg}->{'unresolved'} eq '-'
                . $resolved_targets->{$rslv_tg}->{'ip-address'}
                || $::__EXCLUDED_TARGETS{$excluded_tg}->{'unresolved'} eq '-'
                . $resolved_targets->{$rslv_tg}->{'unresolved'})
            {
                push @invalid_resolved_targets, $rslv_tg;
            }
        }
    }

    for my $invalid_res (@invalid_resolved_targets)
    {
        my $context = $resolved_targets->{$invalid_res}->{'context'};
        delete $context_targets->{$context}->{$invalid_res};
        if (!scalar(keys %{$context_targets->{$context}}))
        {
            delete $context_targets->{$context};
        }
        delete $resolved_targets->{$invalid_res};
    }

}
1;

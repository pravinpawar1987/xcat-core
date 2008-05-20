# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::sles;
use Storable qw(dclone);
use Sys::Syslog;
use xCAT::Table;
use xCAT::Utils;
use xCAT::MsgUtils;
use xCAT::Template;
use xCAT::Postage;
use Data::Dumper;
use Getopt::Long;
Getopt::Long::Configure("bundling");
Getopt::Long::Configure("pass_through");
use File::Path;
use File::Copy;
my $cpiopid;

sub handled_commands
{
    return {
            copycd    => "sles",
            mkinstall => "nodetype:os=sles.*"
            };
}

sub process_request
{
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $distname = undef;
    my $arch     = undef;
    my $path     = undef;
    if ($request->{command}->[0] eq 'copycd')
    {
        return copycd($request, $callback, $doreq);
    }
    elsif ($request->{command}->[0] eq 'mkinstall')
    {
        return mkinstall($request, $callback, $doreq);
    }
}

sub mkinstall
{
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my @nodes    = @{$request->{node}};
    my $node;
    my $ostab = xCAT::Table->new('nodetype');
    my %doneimgs;
    foreach $node (@nodes)
    {
        my $osinst;
        my $ent = $ostab->getNodeAttribs($node, ['profile', 'os', 'arch']);
        unless ($ent->{os} and $ent->{arch} and $ent->{profile})
        {
            $callback->(
                        {
                         error => ["No profile defined in nodetype for $node"],
                         errorcode => [1]
                        }
                        );
            next;    #No profile
        }
        my $os      = $ent->{os};
        my $arch    = $ent->{arch};
        my $profile = $ent->{profile};
        unless ( -r $::XCATROOT . "/share/xcat/install/sles/$profile.tmpl"
              or -r $::XCATROOT . "/share/xcat/install/sles/$profile.$arch.tmpl"
              or -r $::XCATROOT . "/share/xcat/install/sles/$profile.$os.tmpl"
              or -r $::XCATROOT
              . "/share/xcat/install/sles/$profile.$os.$arch.tmpl")
        {
            $callback->(
                      {
                       error =>
                         ["No AutoYaST template exists for " . $ent->{profile}],
                       errorcode => [1]
                      }
                      );
            next;
        }

        #Call the Template class to do substitution to produce a kickstart file in the autoinst dir
        my $tmperr;
        if (-r $::XCATROOT . "/share/xcat/install/sles/$profile.$os.$arch.tmpl")
        {
            $tmperr =
              xCAT::Template->subvars(
                         $::XCATROOT
                           . "/share/xcat/install/sles/$profile.$os.$arch.tmpl",
                         "/install/autoinst/$node",
                         $node
                         );
        }
        elsif (-r $::XCATROOT . "/share/xcat/install/sles/$profile.$arch.tmpl")
        {
            $tmperr =
              xCAT::Template->subvars(
                   $::XCATROOT . "/share/xcat/install/sles/$profile.$arch.tmpl",
                   "/install/autoinst/$node", $node);
        }
        elsif (-r $::XCATROOT . "/share/xcat/install/sles/$profile.$os.tmpl")
        {
            $tmperr =
              xCAT::Template->subvars(
                     $::XCATROOT . "/share/xcat/install/sles/$profile.$os.tmpl",
                     "/install/autoinst/$node", $node);
        }
        elsif (-r $::XCATROOT . "/share/xcat/install/sles/$profile.tmpl")
        {
            $tmperr =
              xCAT::Template->subvars(
                         $::XCATROOT . "/share/xcat/install/sles/$profile.tmpl",
                         "/install/autoinst/$node", $node);
        }
        if ($tmperr)
        {
            $callback->(
                        {
                         node => [
                                  {
                                   name      => [$node],
                                   error     => [$tmperr],
                                   errorcode => [1]
                                  }
                         ]
                        }
                        );
            next;
        }
	
		# create the node-specific post script DEPRECATED, don't do
		#mkpath "/install/postscripts/";
		#xCAT::Postage->writescript($node, "/install/postscripts/".$node, "install", $callback);

        if (
            (
             $arch =~ /x86_64/
             and -r "/install/$os/$arch/1/boot/$arch/loader/linux"
             and -r "/install/$os/$arch/1/boot/$arch/loader/initrd"
            )
            or
            (
             $arch =~ /x86$/
             and -r "/install/$os/$arch/1/boot/i386/loader/linux"
             and -r "/install/$os/$arch/1/boot/i386/loader/initrd"
            )
            or ($arch =~ /ppc/ and -r "/install/$os/$arch/1/suseboot/inst64")
          )
        {

            #TODO: driver slipstream, targetted for network.
            unless ($doneimgs{"$os|$arch"})
            {
                mkpath("/tftpboot/xcat/$os/$arch");
                if ($arch =~ /x86_64/)
                {
                    copy("/install/$os/$arch/1/boot/$arch/loader/linux",
                         "/tftpboot/xcat/$os/$arch/");
                    copy("/install/$os/$arch/1/boot/$arch/loader/initrd",
                         "/tftpboot/xcat/$os/$arch/");
                } elsif ($arch =~ /x86/) {
                    copy("/install/$os/$arch/1/boot/i386/loader/linux",
                         "/tftpboot/xcat/$os/$arch/");
                    copy("/install/$os/$arch/1/boot/i386/loader/initrd",
                         "/tftpboot/xcat/$os/$arch/");
                }
                elsif ($arch =~ /ppc/)
                {
                    copy("/install/$os/$arch/1/suseboot/inst64",
                         "/tftpboot/xcat/$os/$arch");
                }
                $doneimgs{"$os|$arch"} = 1;
            }

            #We have a shot...
            my $restab = xCAT::Table->new('noderes');
            my $bptab = xCAT::Table->new('bootparams',-create=>1);
            my $hmtab  = xCAT::Table->new('nodehm');
            my $ent    =
              $restab->getNodeAttribs(
                                      $node,
                                      [
                                       'nfsserver', 
                                       'primarynic', 'installnic'
                                      ]
                                      );
            my $sent =
              $hmtab->getNodeAttribs($node, ['serialport', 'serialspeed', 'serialflow']);
            unless ($ent and $ent->{nfsserver})
            {
                $callback->(
                           {
                            error => ["No noderes.nfsserver for $node defined"],
                            errorcode => [1]
                           }
                           );
                next;
            }
            my $kcmdline =
                "autoyast=http://"
              . $ent->{nfsserver}
              . "/install/autoinst/"
              . $node
              . " install=http://"
              . $ent->{nfsserver}
              . "/install/$os/$arch/1";
            if ($ent->{installnic})
            {
                $kcmdline .= " netdevice=" . $ent->{installnic};
            }
            elsif ($ent->{primarynic})
            {
                $kcmdline .= " netdevice=" . $ent->{primarynic};
            }
            else
            {
                $kcmdline .= " netdevice=eth0";
            }

            #TODO: driver disk handling should in SLES case be a mod of the install source, nothing to see here
            if (defined $sent->{serialport})
            {
                unless ($sent->{serialspeed})
                {
                    $callback->(
                        {
                         error => [
                             "serialport defined, but no serialspeed for $node in nodehm table"
                         ],
                         errorcode => [1]
                        }
                        );
                    next;
                }
                $kcmdline .=
                    " console=ttyS"
                  . $sent->{serialport} . ","
                  . $sent->{serialspeed};
                if ($sent and ($sent->{serialflow} =~ /(ctsrts|cts|hard)/))
                {
                    $kcmdline .= "n8r";
                }
            }

            if ($arch =~ /x86/)
            {
                $bptab->setNodeAttribs(
                                        $node,
                                        {
                                         kernel   => "xcat/$os/$arch/linux",
                                         initrd   => "xcat/$os/$arch/initrd",
                                         kcmdline => $kcmdline
                                        }
                                        );
            }
            elsif ($arch =~ /ppc/)
            {
                $bptab->setNodeAttribs(
                                        $node,
                                        {
                                         kernel   => "xcat/$os/$arch/inst64",
                                         initrd   => "",
                                         kcmdline => $kcmdline
                                        }
                                        );
            }

        }
        else
        {
            $callback->(
                {
                 error => [
                     "Failed to detect copycd configured install source at /install/$os/$arch"
                 ],
                 errorcode => [1]
                }
                );
        }
    }
    #my $rc = xCAT::Utils->create_postscripts_tar();
    #if ($rc != 0)
    #{
    #    xCAT::MsgUtils->message("S", "Error creating postscripts tar file.");
    #}
}

sub copycd
{
    my $request  = shift;
    my $callback = shift;
    my $doreq    = shift;
    my $installroot;
    $installroot = "/install";
    my $sitetab = xCAT::Table->new('site');
    if ($sitetab)
    {
        (my $ref) = $sitetab->getAttribs({key => installdir}, value);
        print Dumper($ref);
        if ($ref and $ref->{value})
        {
            $installroot = $ref->{value};
        }
    }

    @ARGV = @{$request->{arg}};
    GetOptions(
               'n=s' => \$distname,
               'a=s' => \$arch,
               'p=s' => \$path
               );
    unless ($path)
    {

        #this plugin needs $path...
        return;
    }
    if ($distname and $distname !~ /^sles/)
    {

        #If they say to call it something other than SLES, give up?
        return;
    }
    unless (-r $path . "/content")
    {
        return;
    }
    my $dinfo;
    open($dinfo, $path . "/content");
    while (<$dinfo>)
    {
        if (m/^DEFAULTBASE\s+(\S+)/)
        {
            $darch = $1;
            chomp($darch);
            last;
        }
    }
    close($dinfo);
    unless ($darch)
    {
        return;
    }
    my $dirh;
    opendir($dirh, $path);
    my $discnumber;
    my $totaldiscnumber;
    while (my $pname = readdir($dirh))
    {
        if ($pname =~ /media.(\d+)/)
        {
            $discnumber = $1;
            chomp($discnumber);
            my $mfile;
            open($mfile, $path . "/" . $pname . "/media");
            <$mfile>;
            <$mfile>;
            $totaldiscnumber = <$mfile>;
            chomp($totaldiscnumber);
            close($mfile);
            open($mfile, $path . "/" . $pname . "/products");
            my $prod = <$mfile>;
            close($mfile);

            if ($prod =~ m/SUSE-Linux-Enterprise-Server/)
            {
                my @parts    = split /\s+/, $prod;
                my @subparts = split /-/,   $parts[2];
                unless ($distname) { $distname = "sles" . $subparts[0] };
            }
        }
    }
    unless ($distname and $discnumber)
    {
        return;
    }
    if ($darch and $darch =~ /i.86/)
    {
        $darch = "x86";
    }
    elsif ($darch and $darch =~ /ppc/)
    {
        $darch = "ppc64";
    }
    if ($darch)
    {
        unless ($arch)
        {
            $arch = $darch;
        }
        if ($arch and $arch ne $darch)
        {
            $callback->(
                     {
                      error =>
                        ["Requested SLES architecture $arch, but media is $darch"],
                        errorcode => [1]
                     }
                     );
            return;
        }
    }
    %{$request} = ();    #clear request we've got it.

    $callback->(
         {data => "Copying media to $installroot/$distname/$arch/$discnumber"});
    my $omask = umask 0022;
    mkpath("$installroot/$distname/$arch/$discnumber");
    umask $omask;
    my $rc;
    $SIG{INT} =  $SIG{TERM} = sub { if ($cpiopid) { kill 2, $cpiopid; exit 0; } 
        if ($::CDMOUNTPATH) {
            system("umount $::CDMOUNTPATH");
        }
    };
    my $kid;
    chdir $path;
    my $child = open($kid,"|-");
    unless (defined $child) {
      $callback->({error=>"Media copy operation fork failure"});
      return;
    }
    if ($child) {
       $cpiopid = $child;
       my @finddata = `find .`;
       for (@finddata) {
          print $kid $_;
       }
       close($kid);
       $rc = $?;
    } else {
       exec "nice -n 20 cpio -dump $installroot/$distname/$arch/$discnumber/";
    }
    #  system(
    #    "cd $path; find . | nice -n 20 cpio -dump $installroot/$distname/$arch/$discnumber/"
    #    );
    chmod 0755, "$installroot/$distname/$arch";
    chmod 0755, "$installroot/$distname/$arch/$discnumber";

    if ($rc != 0)
    {
        $callback->({error => "Media copy operation failed, status $rc"});
    }
    else
    {
        $callback->({data => "Media copy operation successful"});
    }
}

1;

# Copyright 2004-2015 Hewlett-Packard Development Company, L.P.
#
# This service tool software, including associated documentation,
# is the property of and contains confidential technology
# of Hewlett-Packard Company or its affiliates.
# Service customer is hereby licensed to use the software only for activities
# specified in the Exhibit SS5, and HP Terms and Conditions of Sale
# and Services, HP Business Terms or HP Global
# Agreement and only during the term of the applicable
# support delivered by HP or its authorized service provider.
# Customer may not modify or reverse engineer, remove,
# or transfer the software or make the software or any resultant
# diagnosis or system management data available to other
# parties without HP.s or its authorized service provider.s
# consent. Upon termination or expiration of the services,
# customer will, at HP.s or its service provider.s option, destroy or
# return the software and associated documentation in its possession.use strict;

# Debug Flags
#    1 - print interesting stuff
#    2 - report addition stuff, like 'steps', 'headers' and step specific goodies
#    4 - don't remove files when no longer needed, noting that this will cause them to be
#        included in email whether you want them or not!
#    8 - show compound field processing, but NOT <> processing
#   16 - print subroutine calls
#   32 - print details of 'file finding/selecting' (see 2048 OR use 2080)
#   64 - instance processing
#  128 - used by colplot
#  256 - exit after showparams call
#  512 - show <> processing and only via CLI
# 1024 - in showparams, skip entries of -1
# 2048 - print even MORE details for file selection

# NOTES on 'float', because I'll forget if I don't write them down
#       and it's NOT perfect either...
# in the simple case, you select a bunch of files and use the ending
# access time of the last one for the plotting time range.  further
# since findFiles() gets called multiple times, you reset the date
# range for subsequent calls to only use the files in the range and
# they essentially get reselected and their headers parsed.
#
# Even if the files were loaded from a different machine and/or
# timezone, things workd correctly.  BUT problems arise if there
# are files mixed in from multiple timeframes since the max date
# will be used to select files and if they've crossed midnight
# some may not be selected.  I have no idea how to deal with this
# unusual case most people may never bump into.
#
# More notes about this sprinkled in the code...

use strict;

#######################################################
#    I n i t i a l i z a t i o n
#######################################################

# for debugging
sub logger
{
  my $text=shift;
  open (FILE, ">>/tmp/log.log");
  print FILE "$text\n";
  close(FILE);
}

# This routine must be called before one can use the buildPage() or buildPingPlot
# routines.  It sets up the $mycfg data structure which is also needed to call the
# 'displayText()' text routine.
sub initConfig
{
  my $mycfg=  shift;

  my $pcFlag= $mycfg->{pcflag};
  my $bindir= $mycfg->{bindir};
  my $libdir= $mycfg->{libdir};
  my $exename=$mycfg->{exename};

  my $cwd=cwd();
  $cwd=~s/\//\\/g    if $pcFlag;

  # First, set up some environmental constants
  $mycfg->{debug}=   0;
  $mycfg->{exebare}= basename($exename);
  $mycfg->{cwd}=     $cwd;
  $mycfg->{sep}=     ($pcFlag) ? "\\" : "/";
  $mycfg->{quote}=   ($pcFlag) ? '"' : '';
  $mycfg->{tempdir}= ($pcFlag) ? 'c:\\temp\\' : '/tmp/';
  $mycfg->{htmlflag}=(defined($ENV{'HTTP_ACCEPT'})) ? 1 : 0;
  $mycfg->{validext}=' tab cpu dsk eln ib net nfs clt ost blk env ';    # be sure to have lead/trail spaces
  $mycfg->{custext}= '';

  # If not a pc, we may need to know our timezone
  $mycfg->{tzone}=(!$pcFlag) ? `date +%z` : '';
  chomp($mycfg->{tzone});

  # This is a default that can be overridden
  $mycfg->{deftimeframe}='auto';

  # Trim any extensions off our script
  $mycfg->{exebare}=~s/\..*//;

  # And only if we're not explictly told to ignore the conf file, load additions defs
  # from it.  Note that the definitions that follow are for calling the plotting
  # routines and NOT initParams.
  return    if defined($mycfg->{ignoreconf}) && $mycfg->{ignoreconf}==1;

  # Look for the 'conf' file (named for executable) in myDir and bindir noting
  # that on a pc there is no /etc but that's ok too.  But if we're already in our
  # bindir (which is usually the case), don't look twice
  my ($cfgfile, $openedFlag)=('', 0);
  $cwd=''    if $cwd eq $mycfg->{bindir};
  foreach my $cfgdir ($cwd, $bindir, '/etc')
  {
    next    if $cfgdir eq '';

    $cfgfile="$cfgdir$mycfg->{sep}$mycfg->{exebare}.conf";
    if (open CONFIG, "<$cfgfile")
    {
      $openedFlag=1;
      #displayText($mycfg, "Loading config from '$cfgfile'");
      last;
    }
  }
  liberror($mycfg, "Couldn't find any copies of '$mycfg->{exebare}.conf' to open")    if !$openedFlag;

  my $num=0;
  foreach my $line (<CONFIG>)
  {
    $num++;
    next    if $line=~/^\s*$|^\#/;    # skip blank lines and comments

    if ($line!~/=/)
    {
      displayText($mycfg, "CONFIG ERROR:  Line $num doesn't contain '='.  Ignoring...");
      next;
    }

    # Note - it's to have invalid command paths if they're not used (eg gs)
    # Also note if we move files from a PC to Linux, the pc sticks in a \r
    # so instead of using 'chomp()', lets get rid of both terminators this way.
    my ($param, $value);
    $line=~s/[\n\r]//g;
    ($param, $value)=split(/\s*=\s*/, $line, 2);
    #displayText($mycfg, "$param=$value");

    # The value for GnuPlot is actually a list of potential binaries
    if ($param=~/GnuPlot/)
    {
      foreach my $path (split(/:/, $value))
      {
        if (-e $path)
        {
	  $value=$path;
	  last;
	}
      }
    }

    $mycfg->{$param}=$value;
  }
  close CONFIG;

  #    P o s t    C o n f i g    F i l e    T e s t s    &    P r o c e s s i n g

  # These are the 2 commands that differ based on whether we're a pc or linux box and
  # we don't know the linux paths until after we've loaded the config
  $mycfg->{copy}=   ($pcFlag) ? 'copy /y' : "$mycfg->{CP} -f";
  $mycfg->{del}=    ($pcFlag) ? 'del'     : "$mycfg->{RM} -f";

  my $deftime= $mycfg->{deftimeframe};
  liberror($mycfg, "Invalid value for 'deftimeframe' in colplot.conf: $deftime")    if $deftime!~/^auto$|^none$|^float$|^float=\d+$/;
  liberror($mycfg, "deftimeframe=float only applies to web-based colplot")          if $deftime=~/float/ && !$mycfg->{htmlflag};

  # There's no easy way around this unless I want to force linux gnuplot people to
  # edit the version in the 'conf' file OR not allow this to be run on a PC.  Since
  # we CAN tell the gnuplot version on a linux box it's much safer to just ask it
  # what it's version is and simlpy ignore whatever is in the 'conf' file.
  my $gnuPlot=$mycfg->{GnuPlot};
  liberror($mycfg, "Cannot find gnuplot at path: $gnuPlot.  It is obviously misconfigured in colplot.conf")    if !-e $gnuPlot;
  if (!$pcFlag)
  {
    my $temp=`echo show version | $gnuPlot 2>&1`;
    $temp=~/[vV]ersion (\d+\.\d+)/;
    $mycfg->{GnuVersion}=$1;

    # Assume a font size of small if we can't force it.
    $mycfg->{fontSize}='small';
    $temp=`(echo set terminal png ; echo show terminal) | $gnuPlot 2>&1`;
    $mycfg->{fontSize}='medium'    if $temp=~/medium/;
  }

  # I know, it's a hack, but if running gnuplot<4, we can't include colors with lt in the conf file
  # so remove everything after and including whitespace after the line type number
  if  ($mycfg->{GnuVersion}<4)
  {
    for my $id (keys %$mycfg)
    {
      next    if $id!~/^lt/;
      $$mycfg{$id}=~s/\s+.*//;
      print "Mycfg{$id}: $$mycfg{$id}\n";
    }
  }

  # This can only happen on a PC on linux we get the version from gnuplot itself!
  liberror($mycfg, "You forgot to specify gnuplot version in colplot.conf!!!\n")
      if !defined($mycfg->{GnuVersion});

  #    C u s t o m    E x t e n s i o n    P r o c e s s i n g

  # Reading the following comments confirms I'm clueless!  I don't see why I can't just load
  # these defs along with the others in initParamsInit() but I'm afraid to change it AND
  # since it works, why mess around with it

  # I can't remember why I chose to load the definitions so late in the game via
  # initParamsInit(), but I really want to store custom file extension mappings
  # with the plot defs, so let's just read that bit here using same 'location'
  # rules.  The following stolen from initParamsInit()...
  my (%visited, @cfgFiles);
  my $defsFile='';
  my $sep=$mycfg->{sep};
  foreach my $dir ($libdir, $bindir, $cwd)
  {
    # make sure we don't visit same directory twice
    next    if $dir eq '' || $dir eq '.';
    next    if defined($visited{$dir});
    $visited{$dir}='';

    # The last directory we find colplotlib.defs is is the one we
    # load ALL 'defs' from.  If we don't find it we'll trip an
    # error later on so no need to duplicate that checking here
    my $temp="$dir${sep}colplotlib.defs";
    $defsFile=$temp    if -e $temp;
    foreach my $cfgFile (glob("$dir$sep*.defs"))
    {
      next    if $cfgFile=~/colplotlib\.defs/;
      push @cfgFiles, $cfgFile;
    }
  }
  unshift @cfgFiles, $defsFile;

  my $found=0;
  foreach my $file (@cfgFiles)
  {
    my $extHead=0;
    open CFG, "<$file" || liberror($mycfg, "Couldn't open '$file'");
    foreach my $line (<CFG>)
    {
      next    if $line=~/^\s*$|^#/;

      if ($line=~/<extmaps>/)
      {
        $extHead=1;
        next;
      }
      next    if !$extHead;

      if ($extHead)
      {
        last    if $line=~/^</;    # new header so we're done
        $found=1;
        chomp $line;

	my ($ext, $colName)=split(/\s+/, $line);
	$mycfg->{validext}.="$ext ";
        $mycfg->{custext}.= "$ext:$colName ";
      }
    }
  }
}

##################################################
#    L o a d    P l o t    D e f i n i t i o n s
##################################################

# This must be called first to initialize the environment (but only by
# whomever is calling 'initParams()' and not necessary the main program
# as can be seen by routines like 'buildPage()' and 'buildPngPlot()'.
sub initParamsInit
{
  my $mycfg= shift;
  my $cfgref=shift;

  my $debug=   $mycfg->{debug};
  my $sep=     $mycfg->{sep};
  my $cwd=     $mycfg->{cwd};
  my $bindir=  $mycfg->{bindir};
  my $libdir=  $mycfg->{libdir};

  my (%DescPlots, %DescHeaders);

  # if running out of bindir, set up to ignore $cwd
  $cwd=''    if $cwd eq $bindir;

  my (%visited, @cfgFiles);
  my $defsFile='';
  my $foundFlag=0;
  foreach my $dir ($libdir, $bindir, $cwd)
  {
    # make sure we don't visit same directory twice
    next    if $dir eq '' || $dir eq '.';
    next    if defined($visited{$dir});
    $visited{$dir}='';

    # The last defs file we see is the ONE and only one we ultimately load
    my $temp="$dir${sep}colplotlib.defs";
    $defsFile=$temp    if -e $temp;
    foreach my $cfgFile (glob("$dir$sep*.defs"))
    {
      $foundFlag=1;
      next    if $cfgFile=~/colplotlib\.defs/;
      push @cfgFiles, $cfgFile;
    }
  }

  # If we can't find ANY defs files, it's fatal!
  if (!$foundFlag)
  {
    displayText($mycfg, "Couldn't find ANY '*.defs' files");
    return(0);
  }

  if ($defsFile eq '')
  {
    my $temp="Couldn't find a copy of colplotlib.defs anywhere!\n";
    $temp.="If this is what you intend create an empty one.";
    displayText($mycfg, $temp);
    return(0);
  }
  unshift @cfgFiles, $defsFile;

  foreach my $cfgFile (@cfgFiles)
  {
    my $type=0;
    my $state=0;
    my $descFlag=0;
    my $record='';
    displayText($mycfg, "Loading plot definitions from $cfgFile")    if $debug & 1;
    open CFG, "<$cfgFile" or die "Couldn't open '$cfgFile'";
    while (my $line=<CFG>)
    {
      chomp $line;
      $line=~s/\r//;   # some edits made on PC
      next    if $line=~/^#|^s*$/;    # in case '<' in definition

      if ($line=~/^<(\S+)>/)
      {
        my $ident=$1;
        $type=1    if $ident=~/allplots/;
        $type=2    if $ident=~/allheaders/;
        $type=3    if $ident=~/descplots/;
        $type=4    if $ident=~/macros/;
        $type=5    if $ident=~/extmaps/;    # we actually ignore this stanza as it's process by initConfig()
        next;
      }

      # This should NOT happen, but we've all heard that before...
      liberror($mycfg, "$cfgFile didn't start with a valid header")    if $type==0;

      #    A l l    P l o t s    a n d    H e a d e r s

      # build up long strings consisting of all lines through the trailing '}';
      my $operators;
      if ($type==1 || $type==2 || $type==3)
      {
        $record.=$line;
        if ($record=~/}/)
        {
          # Make sure there is whitespace after leading '{' and before trailing '}'
          # or out split below won't work right
          $record=~s/{/{ /;
	  $record=~s/}/ }/;

          # Very first token is the name of the entry and the rest is a set of pieces
          # of the form 'name=value'.  This is pretty rare, but if someone (like me)
          # decides to override one of the existing plots in their own 'defs' file,
          # the original settings (like mask) will still be defined.  This assures we
          # start with a clean slate.
          my ($entry, $therest)=split(/\s+/, $record, 2);
          delete  $cfgref->{AllPlots}->{$entry}    if $type==1;
          foreach my $piece (split(/\s+/, $therest))
          {
            next    if $piece=~/{/;
            last    if $piece=~/}/;

            my ($name, $value)=split(/=/, $piece);
	    $value=''    if !defined($value);

            liberror($mycfg, "invalid ptype '$value' for plot '$entry'")    if $name=~/ptype/ && $value!~/^[lp]s*$/;

	    if ($type==1 && $name=~/yname/)
            {
              my $operators='';
	      my $numComp=0;

              # We have to split on ',[' instead of just ',' because the new <> syntax allows commas
	      foreach my $header (split(/,\[/, $value))
              {
	        $header="[$header"    if $header!~/^\[/;    # all but first have leading '[' split off
		liberror($mycfg, "cannot start 'yname' expression '$header' with number for plot '$entry'")
			if $header=~/^\d/;

                # we're tucking the magic for expanding <...> in headers into a common routine
                # This appears to work and though tested pretty well not sure what would happen
                # with arbitrarily complext expressions so use with caution.
                if ($header=~/\</)
                {
		  $header=expandHeader($mycfg, $header);
                  print "NewHeader: $header\n"    if $debug & 512;
                }

		my $firstComp=1;
                while ($header ne '')
                {
                  my $oper;
		  # This pattern is going to take some explaining!  We can't just look for a
                  # a +,-,*,/ (I originally thougth I could) because some ynames contain a '/'
                  # such as ctx/sec and I don't want to change collectl!  The good news is we
                  # know they have to be followed by another header starting with '[' or a
                  # constant which MUST start with a number or a decimal point.
		  if ($header=~/.*?([\+\-\*\/])([\[\d\.].*)/)
                  {
		    $oper=$1;
		    $header=$2;
		    $numComp++    if $firstComp;
		    $firstComp=0;
                  }
                  else
                  {
                    $header='';
		    $oper=' ';
                  }
                  $operators.="$oper,";
                }
              }

              # in addition to chopping trailing comma, we need each piece of a compound
              # expression to look like a separate field so change the operators to commas
              # being careful not to interpret an symbol in a field name (like int/sec)
              # as a real operator
              $operators=~s/,$//;
	      $value=~s/[\+\-\*\/]([\[\d\.])/,$1/g;
              $cfgref->{AllPlots}->{$entry}->{numcomp}=$numComp;
              $cfgref->{AllPlots}->{$entry}->{oper}=$operators;
            }

            $cfgref->{AllPlots}->  {$entry}->{$name}=$value    if $type==1;
            $cfgref->{AllHeaders}->{$entry}->{$name}=$value    if $type==2;

            if ($type==3)
            {
              # once we see the 'desc' field, which has a value of the 1st word
              # we simply append each new word onto the desc.
              $cfgref->{PlotDesc}->{$entry}->{desc}.=" $name"    if $descFlag;
              $cfgref->{PlotDesc}->{$entry}->{$name}=$value      if !$descFlag;
	      $descFlag=1    if $name eq 'desc';
            }
          }

          if ($type==2)
          {
            $cfgref->{AllHeaders}->{$entry}->{ymin}=0        if !defined($cfgref->{AllHeaders}->{$entry}->{ymin});
            $cfgref->{AllHeaders}->{$entry}->{ymax}=1000     if !defined($cfgref->{AllHeaders}->{$entry}->{ymax});
            $cfgref->{AllHeaders}->{$entry}->{ydivisor}=1    if !defined($cfgref->{AllHeaders}->{$entry}->{ydivisor});
          }
        }
        $record='';
        $descFlag=0;
      }

      #    M a c r o    D e f i n i t i o n s

      elsif ($type==4)
      {
        my ($name, $therest)=split(/\s+/, $line, 2);
        foreach my $plot (split(/[, ]/, $therest))
        {
          liberror($mycfg, "macro '$name' specifies the plot name '$plot', which doesn't exist")
	        if !defined($cfgref->{AllPlots}->{$plot}) && !defined($cfgref->{Macros}->{$plot});
          }
        $cfgref->{Macros}->{$name}=$therest;
      }
    }
  }

  #    O v e r r i d e  /  C o n s i s t e n c y    C h e c k s

  # This will eventually contain a list of all possible headers mentioned in the
  # plot definitions in all the cfg files!
  my %allHeaders;
  my $allHeaders='';

  # Now override any undefined plot valued with entries from headers or set them
  # to global default if not defined there either.
  foreach my $name (keys %{$cfgref->{AllPlots}})
  {
    my $numComp=$cfgref->{AllPlots}->{$name}->{numcomp};
    if ($numComp)
    {
      my @labels=split(/,/, $cfgref->{AllPlots}->{$name}->{clabels});
      my $numLabels=scalar(@labels);
      liberror($mycfg, "You defined a compound plot '$name', but no 'clabels' field")
	  if !defined($cfgref->{AllPlots}->{$name}->{clabels});
      liberror($mycfg, "plot '$name' has $numComp compound lines, but only $numLabels 'clabels' fields")
	  if $numLabels<$numComp;
    }

    # Make sure all fields defined that get referenced later
    $cfgref->{AllPlots}->{$name}->{clabels}=''    if !defined($cfgref->{AllPlots}->{$name}->{clabels});

    # For header oriented elements (ymin/ymax/ylabel/ydivisor) build up string based on default
    # values in case we need it later.
    my ($ymin, $ymax, $ylabel, $ydiv)=('','','','');
    foreach my $header (split(/,/, $cfgref->{AllPlots}->{$name}->{yname}))
    {
      # If someone leaves off a header entry, because they know they want the same name
      # as the column with a minimum of 0 and a divisor of 1, just set them up here.  The
      # only catch is 'ymax', which is NOT always needed, but to be safe we'll set it
      # to an invalid value and expect (but not force) the user to override it in 'AllPlots'.
      if (!defined($cfgref->{AllHeaders}->{$header}))
      {
        $cfgref->{AllHeaders}->{$header}->{ymin}=0;
        $cfgref->{AllHeaders}->{$header}->{ymax}=-1;
        $cfgref->{AllHeaders}->{$header}->{ydivisor}=1;
        $cfgref->{AllHeaders}->{$header}->{ylabel}=substr($header, index($header,']')+1);
      }

      #  Build a 'fake' header line that consists of all headers we haven't seen before
      $allHeaders.="$header "    if !defined($allHeaders{$header});
      $allHeaders{$header}=1;

      # It actually felt simpler to assume these values weren't defined in 'AllPlots'
      # and so we'll build up a list of them in advance of checking and then override
      # as need be,
      $ylabel.="$cfgref->{AllHeaders}->{$header}->{ylabel},";
      $ymin.=  "$cfgref->{AllHeaders}->{$header}->{ymin},";
      $ymax.=  "$cfgref->{AllHeaders}->{$header}->{ymax},";
      $ydiv.=  "$cfgref->{AllHeaders}->{$header}->{ydivisor},";

      my $numComp=0;
      $numComp++    if $cfgref->{AllPlots}->{$name}->{oper} ne ' ';
    }
    $ymin=~s/,$//;
    $ymax=~s/,$//;
    $ydiv=~s/,$//;
    $ylabel=~s/,$//;

    if (defined($cfgref->{AllPlots}->{$name}->{clabels}))
    {
      $ymin=propCompound($cfgref, $name, $ymin, 'cymin');
      $ymax=propCompound($cfgref, $name, $ymax, 'cymax');
    }

    # Now reset any fields not yet defined
    $cfgref->{AllPlots}->{$name}->{ymin}=$ymin         if !defined($cfgref->{AllPlots}->{$name}->{ymin});
    $cfgref->{AllPlots}->{$name}->{ymax}=$ymax         if !defined($cfgref->{AllPlots}->{$name}->{ymax});
    $cfgref->{AllPlots}->{$name}->{ylabel}=$ylabel     if !defined($cfgref->{AllPlots}->{$name}->{ylabel});
    $cfgref->{AllPlots}->{$name}->{ydivisor}=$ydiv     if !defined($cfgref->{AllPlots}->{$name}->{ydivisor});

    # There are only 1 instance of these and the mask must be in the AllPlots definitions
    $cfgref->{AllPlots}->{$name}->{mask}=0             if !defined($cfgref->{AllPlots}->{$name}->{mask});
    $cfgref->{AllPlots}->{$name}->{ptype}='l'          if !defined($cfgref->{AllPlots}->{$name}->{ptype});
  }
  $cfgref->{AllHeaders}=$allHeaders;
  return(1);
}

sub expandHeader
{
  my $mycfg= shift;
  my $header=shift;

  my $debug=$mycfg->{debug};
  print "Expanding: $header\n"    if $debug & 512;
  return($header)    if $header!~/</;

  my $therest;
  my $newHeader='';
  while ($header ne '')
  {
    ($header, $therest)=split(/\+/, $header, 2);
    $therest=''    if !defined($therest);
    print "Header: $header  Rest: $therest\n"    if $debug & 512;

    # epxand entry by converting the expression in the <> to a list of numbers
    if ($header=~/(.*?)<(.*?)>(.*)/)
    {
      my $prefix=$1;
      my $range= $2;
      my $suffix=$3;

      $range=~s/-/../g;
      my @numbers=eval("($range)");
      foreach my $number (@numbers)
      {
        # Repeat the expession with each value, adding them together
        # recursively in case multiple <>s
        $newHeader.=expandHeader($mycfg, "$prefix$number$suffix").'+';
      }
    }
    else
    {
      $newHeader.=$header.'+';
    }
    $header=$therest;
  }
  $newHeader=~s/\+$//;
  return($newHeader);
}

sub propCompound
{
  my $cfgref=shift;
  my $name=  shift;
  my $fields=shift;
  my $label= shift;

  # we don't always have an overrides field specified but still need to go through
  # each field in case one is numberic.
  my $overFlag=(defined($cfgref->{AllPlots}->{$name}->{$label})) ? 1 : 0;

  # Even if no overrides for ymin/ymax, this is the one loop where we inspect each
  # field and so need to verify if a numeric that there IS an override specified.
  my @fields=split(/,/, $fields);
  my @names=split(/,/, $cfgref->{AllPlots}->{$name}->{yname});
  my @opers=split(/,/, $cfgref->{AllPlots}->{$name}->{oper});
  my @overs=split(/,/, $cfgref->{AllPlots}->{$name}->{$label})    if $overFlag;
  my ($operMode, $overIndex)=(0,0);
  my $newList='';
  for (my $i=0; $i<scalar(@fields); $i++)
  {
    #print "I: $i  FIELD: $fields[$i]  OPER: $opers[$i]  NAME: $names[$i]\n";
    $fields[$i]=$fields[$i-1]    if $names[$i]=~/^\d/;
    if ($overFlag && ($operMode || $opers[$i] ne ' '))
    {
      # The last operator of compound mode always ' '
      $newList.="$overs[$overIndex],";
      $operMode=($opers[$i] ne ' ') ? 1 : 0;
      $overIndex++    if $operMode==0 && ($overIndex+1)<scalar(@overs);
    }
    else
    {
      $newList.="$fields[$i],";
    }
  }
  $newList=~s/,$//;
  return($newList);
}

#################################
#   B u i l d    A    P a g e
#################################

# In the case of a web-based environment, this routine actually returns a list of
# hrefs, leaving it up to the caller to decide how to actually format the page.
# For terminal-based output, the plots will be generated/displayed by gnuplot.
# For file/email output, the output file will be produced and its name returned.
# This means it will be up to the caller to deliver email and ultimately remove it.
sub buildPage
{
  my $mycfg=  shift;
  my $pparams=shift;

  my $debug=   $mycfg->{debug};
  my $sep=     $mycfg->{sep};
  my $uiType=  $pparams->{uitype};
  displayText($mycfg, "BuildPage")     if $debug & 16;

  ######################################################
  #    STEP 0:  Validate params and get file extenstion
  ######################################################

  displayText($mycfg, "Step0")    if $debug & 2;

  # Not very likely but VERY necessary!
  liberror($mycfg, "You need to have uuencode installed to send mail.  Is the value of UUENCODE in your 'conf' file wrong?")
          if $pparams->{email}=~/@/ && !-e $mycfg->{UUENCODE};

  my %validExt;
  my $config={};
  initParamsInit($mycfg, $config);

  my %custTag;
  foreach my $custext (split(/\s+/, $mycfg->{custext}))
  {
    my ($ext, $headers)=split(/:/, $custext, 2);
    foreach my $tag (split(/\|/, $headers))
    {
      print "Defined custom extension: $ext for header: $tag\n"    if $debug & 1;
      $custTag{"[$tag"}=$ext;
    }
  }

  my $plots=$pparams->{plots};

  # Make a quick first pass to validate the names and if we were passed a 'macro'
  # expand it!  If a macro was indeed encoutered, go back AGAIN and see if that
  # specified one.  At least for now, a macro needs to be defined before it can
  # used in another one.
  while(1)
  {
    my $macroFlag=0;
    foreach my $plot (split(/[, ]/, $plots))
    {
      if (!defined($config->{AllPlots}->{$plot}) && !defined($config->{Macros}->{$plot}))
      {
        displayText($mycfg, "Invalid plot: $plot");
        exit;
      }

      if (defined($config->{Macros}->{$plot}))
      {
        $plots=~s/$plot/$config->{Macros}->{$plot}/;
        $macroFlag=1;
      }
    }
  last    if !$macroFlag;
  }

  # Build up a list by extension of all the plots that apply to each file
  foreach my $plot (split(/[, ]/, $plots))
  {
    # get tag of first column, noting by design they're all the same
    $config->{AllPlots}->{$plot}->{yname}=~/(\[.*?)\]/;
    my $tag=$1;

    my $ext='tab';
    $ext='cpu'               if $tag=~/CPU:/;
    $ext='dsk'               if $tag=~/DSK:/;
    $ext='eln'               if $tag=~/ELAN:/;
    $ext='ib'                if $tag=~/IB:/;
    $ext='net'               if $tag=~/NET:/;
    $ext='nfs'               if $tag=~/NFS:|NFS2CD|NFS2SD|NFS3CD|NFS3SD|NFS4CD|NFS4SD/;
    $ext='clt'               if $tag=~/CLT:|CLTB:|CLTM:|CLTR:/;
    $ext='ost'               if $tag=~/OST:|OSTB:/;
    $ext='blk'               if $tag=~/OSTD:/;
    $ext='env'               if $tag=~/ENV:/;

    # see if this is a custom plot (not usually)
    $ext=$custTag{$tag}      if defined($custTag{$tag});    # '$tag' actually starts with '['

    # Build up a list of valid extensions so we know which files to look at.  We also
    # save a list of the plot names associated with each so we know which plots to
    # pass to initParams later on
    $validExt{$ext}=''       if !defined($validExt{$ext});
    $validExt{$ext}.="$plot,";
    displayText($mycfg, "Plot: $plot  Tag: $tag  Ext: $ext  Val: $validExt{$ext}")    if $debug & 1;
  }

  ##################################################
  #    STEP 1:  Build list of matching files/headers
  ##################################################

  # The trick here is we need to be sure to group everything by file extension so that
  # if multiple files need to be plotted together they can be.
  displayText($mycfg, "Step1")    if $debug & 2;

  # This will return a list of all the plots matching the date/contains selection criteria
  # Also note that findFiles will also reset 'fdate' and 'tdate' between passes, potentially
  # altering the search criteria and so we need to reset it between passes.  Since this is
  # the only place where 'findFiles()' is called mulitple times, this is the only place
  # this occurs.
  my $match=0;
  my $selected={};
  my $dir=$pparams->{dir};
  my ($saveFrom, $saveThru)=($pparams->{fdate}, $pparams->{tdate});
  foreach my $ext (sort keys %validExt)
  {
    $pparams->{fdate}=$saveFrom;
    $pparams->{tdate}=$saveThru;
    $match+=findFiles(1, $mycfg, $pparams, "$dir$sep*.$ext", $selected);
  }
  return(())    if !$match;

  if ($pparams->{datefix} eq 'off')
  {
    $pparams->{fdate}=$saveFrom;
    $pparams->{tdate}=$saveThru;
  }

  showSelected($mycfg, 'Step1', $selected, 1)    if $debug & 32;

  ##########################################################
  #    STEP 2:    Call initParams to get plotting parameters
  ##########################################################

  displayText($mycfg, "Step2")    if $debug & 2;

  # this will tell the uniform number of plots per file
  $pparams->{numuniform}=-1;

  # Filters and Html constant, but we deal with plots one at a time.
  my $numsel=0;
  my $globinfo={};
  my $yminwidth=0;  # see comment(s) later on
  my $select={filters=>$pparams->{filters}};
  foreach my $ext (sort keys %$selected)
  {
    foreach my $prefix (sort keys %{$selected->{$ext}})
    {
      foreach my $date (sort keys %{$selected->{$ext}->{$prefix}})
      {
        # This is at least true on my laptop!
        my $maxIndex=scalar(@{$selected->{$ext}->{$prefix}->{$date}});
        if ($mycfg->{GnuVersion}<4 && $mycfg->{pcflag} && $selected->{$ext}->{$prefix}->{$date}->[$maxIndex-1]->{dayspan}>7)
        {
          my $tempText= "You have selected to plot more than 7 days worth of data on a single plot on a PC.\n";
          $tempText.=   "In at least some cases this generates exception errors on 'Windows'!  gnuplot V4\n";
          $tempText.=   "seems to work so try upgrading (don't forget to put version in $mycfg->{exebare}.conf).";
          liberror($mycfg, $tempText);
        }

        # Now, for each file, build up a list of plotting parameters.
        foreach (my $index=0; $index<$maxIndex; $index++)
        {
          # We're only passing the filename as a debugging aid so when we get in over our
          # heads we can figure out how the hell we got there!
          my $plotinfo=[];
          $select->{plots}=$validExt{$ext};
          $select->{plots}=~s/,$//;
          $select->{fileinfo}=$selected->{$ext}->{$prefix}->{$date}->[$index];
          $select->{filename}=$selected->{$ext}->{$prefix}->{$date}->[$index]->{fullname};
          $select->{plottype}=$pparams->{plottype}
	        if defined($pparams->{plottype}) && $pparams->{plottype}!~/default/i;

          # Count the number of plots we're about to generate and if the current file doesn't
          # have any we need to delete the entire structure entry for it.
          my $header=$selected->{$ext}->{$prefix}->{$date}->[$index]->{header};
          my $number=initParams($mycfg, $config, $select, \$header, $plotinfo, $globinfo);
          if ($number==0)
          {
            displayText($mycfg, "Delete Selection selected->{$ext}->{$prefix}->{$date}->[$index]")
		if $debug & 32;
	    delete $selected->{$ext}->{$prefix}->{$date}->[$index];
            next;
          }

	  # Add the selected parameters to our plotting structure.  Also note that since we're
          # generating the same plot for all the files, the data returned in '$globinfo{}' will
          # be the same so it's ok to (re)set it on each call to initParams.
          if ($number)
          {
	    # for cli-based output it can be useful to know if there are a
            # non-uniform number of plots/page
	    if ($uiType==2)
	    {
	      $pparams->{numuniform}=$number    if $pparams->{numuniform}==-1;
	      $pparams->{numuniform}=0          if $pparams->{numuniform}!=$number;
	    }

	    $numsel+=$number;
	    $selected->{$ext}->{$prefix}->{$date}->[$index]->{plotinfo}=$plotinfo;

	    my $filename=basename($selected->{$ext}->{$prefix}->{$date}->[$index]->{fullname});
            showParams($mycfg, $plotinfo, $filename)    if $pparams->{showparams};

            # Determine the maximum width of all the 'minor' Y axes noting we'll ignore when 'tty'
            # in which case we were passed the width via --yminwidth
            $yminwidth=$globinfo->{yminwidth}    if $yminwidth<$globinfo->{yminwidth};

            # Make sure we don't have too many y-axes
            liberror($mycfg, "At least one plot has > 2 y-axes which is to many for gnuplot!.  Try using -showparams")
	        if $globinfo->{ymaxaxes}>2;
          }
        }
      }
    }
  }

  displayText($mycfg, "Selected $numsel plots")    if $debug & 1;
  return(())    if !$numsel;
  showSelected($mycfg, 'Step2', $selected, 2)    if $debug & 32;

  ##########################################################
  #    STEP 3:    Generate Plots OR hrefs (if webbased)
  ##########################################################

  $pparams->{yminwidth}=$yminwidth    unless $pparams->{filetype} eq 'tty';
  displayText($mycfg, "Step3 - NumSel: $numsel  MinWidth: $yminwidth")    if $debug & 2;

  my $context={};
  $context->{state}=1;
  $context->{plotnum}=0;
  $context->{plotsperpage}=int(1/$pparams->{height});

  # PDFs can't be wider than a page
  if ($pparams->{email} ne '' && $pparams->{width}>1 && $pparams->{filetype} eq 'pdf')
  {
    displayText($mycfg, "Warning: Plot width reset to 1 to fit page", 3);
    $pparams->{width}=1;
  }

  # These 2 variables are used for web-based output
  my $hrefs=[];
  my $lastPrefix='';
  foreach my $ext (sort keys %$selected)
  {
    foreach my $prefix (sort keys %{$selected->{$ext}})
    {
      # Force new page if prefix changes and pagebreak mode requested
      my $pagbrk=$pparams->{pagbrk};
      $context->{plotnum}=0    if $pagbrk=~/on/ && $prefix ne $lastPrefix;
      $lastPrefix=$prefix;

      foreach my $date (sort keys %{$selected->{$ext}->{$prefix}})
      {
        # we now have a unique file spec, so loop though all the plots associated with
        # the base plotting info.  Since we don't necessarily have plotting data for the
        # first or last files in the selection list, we need to use the index of the first
        # one that does! This same technique is used in plotit() as well.
        my $maxIndex=scalar(@{$selected->{$ext}->{$prefix}->{$date}});
        my ($firstIndex, $lastIndex);
        my $instances=' ';
        foreach (my $fileIndex=0; $fileIndex<$maxIndex; $fileIndex++)
        {
          my $tempinfo=$selected->{$ext}->{$prefix}->{$date}->[$fileIndex]->{plotinfo};
          if (defined($tempinfo))
          {
            $lastIndex= $fileIndex;
            $firstIndex=$fileIndex    if !defined($firstIndex);

	    # Build a list all unique instance names
            my $plotinfo=$selected->{$ext}->{$prefix}->{$date}->[$firstIndex]->{plotinfo};
	    for (my $plotIndex=0; $plotIndex<scalar(@$tempinfo); $plotIndex++)
            {
              if ($tempinfo->[$plotIndex]->{InstName} ne '')
              {
		my $instance=$tempinfo->[$plotIndex]->{InstName};
		$instances.="$instance "    if $instances!~/ $instance /;
              }

	      printf "File$fileIndex: %s Plot$plotIndex: Name %s  InstName: $tempinfo->[$plotIndex]->{InstName}\n",
			$selected->{$ext}->{$prefix}->{$date}->[$fileIndex]->{fullname},
			$tempinfo->[$plotIndex]->{PlotName}
				if $debug & 64;
            }
          }
        }
	next    if !defined($firstIndex);    # if no plotting data for this plot/file

        $instances=~s/^ //;
        $instances=~s/ $//;
        print "Instances: $instances\n"    if $debug & 64;

        # At least one file somewhere has plotting data, but does if have data for each plot?
        my $plotinfo=$selected->{$ext}->{$prefix}->{$date}->[$firstIndex]->{plotinfo};
        $context->{dayspan}=$selected->{$ext}->{$prefix}->{$date}->[$lastIndex]->{dayspan};

        # By ultimately passing $allPlotsInfo to plotit, it has access to everything, not just
        # the plot it's being asked to generate
        my $allPlotsInfo=$selected->{$ext}->{$prefix}->{$date};

        for (my $plotIndex=0; $plotIndex<scalar(@$plotinfo); $plotIndex++)
        {
          # web-based output generates a list of hrefs, everthing else generates a single ctl
          # file and executes it.  If terminal based output, the plots are immediately displayed
          # and in all other cases the name of the output file will be returned.
	  if ($uiType==1 && $pparams->{email} eq '')
          {
            # Just because we know the selected file(s) has some plotting data for something, we
            # don't know if there is any data for THIS specific plot...
            my $hasData=0;
            my $fileIndex;
            foreach ($fileIndex=$firstIndex; $fileIndex<=$lastIndex; $fileIndex++)
            {
	      if (defined($allPlotsInfo->[$fileIndex]->{plotinfo}->[$plotIndex]))
              {
	        $hasData=1;
	        last;
              }
            }

            genhrefs($mycfg, $hrefs, $pparams, $allPlotsInfo, $fileIndex, $plotIndex)
		if $hasData;
          }
          else
          {
            if ($instances eq '')
            {
              # new index, new plot (note index WILL be zero if forced page above)
              $context->{plotnum}++;
              $context->{plotnum}=1     if $context->{plotnum}>$context->{plotsperpage};

	      # If we didn't actally have any data for a specific plot, which is rare, AND we
              # got this far reset the plot number so we can track number/page
	      plotit($mycfg, $context, $pparams, $allPlotsInfo, $globinfo, $plotIndex)
		  or $context->{plotnum}--;
            }
          }
        }

	# Instance plotting handled differently because we need one call/instance independent
        # of the instance index in the previous loop since there can be MORE instances than
        # indexes as in the case of 2 unique files where one has sda,sdb and the other has sda,sdc
        # here we have a max of 2 indexes but 3 instances
        foreach my $inst (split(/ /, $instances))
	{
          # new index, new plot (note index WILL be zero if forced page above)
          $context->{plotnum}++;
          $context->{plotnum}=1     if $context->{plotnum}>$context->{plotsperpage};

          plotit($mycfg, $context, $pparams, $allPlotsInfo, $globinfo, 0, $inst)
                or $context->{plotnum}--;
        }
      }
    }
  }

  # For web-based output we just return a list of hrefs...
  my $email=$pparams->{email};
  return(@$hrefs)    if $uiType==1 && $email eq '';

  # Finish off last control file for terminal/file based output
  $context->{state}=3;
  plotit($mycfg, $context, $pparams, undef, undef, undef, $debug);

  ##########################################################
  #    STEP 4:    Plotting
  ##########################################################

  my $filetype=$pparams->{filetype};
  displayText($mycfg, "Step4 - plotting  Dest: $email  FileType: $filetype")    if $debug & 2;

  # A non-blank return will signal success for terminal-based output
  my $outputFile=1;

  if ($filetype!~/term|tty/)
  {
    my $copy=    $mycfg->{copy};
    my $del=     $mycfg->{del};
    my $sep=     $mycfg->{sep};
    my $tempdir= $mycfg->{tempdir};
    my $pdfFile="$tempdir$$-colplot.pdf";
    my $tarFile="$tempdir$$-colplot.tar";

    # We're not displaying the output on a brower, so either collect it
    # up in a file, either as separate objects OR one big 'ps' file.  In
    # any event, package it up and either mail it to $email OR move it
    # to the specified directory.
    my $command;

    # to make this comparison work on both dos and unix, we need to remove
    # dos partition name and any trailing \s
    my $temp=$tempdir;
    my $metaSep=quotemeta($sep);
    $temp=~s/\w+:|$metaSep$//g;
    my $email=$pparams->{email};

    my $usingTempDir=((-d $email && $email eq $temp) || (!-e $email && dirname($email) eq $temp)) ? 1 : 0;

    # At this point we either have a pdf, multiple pngs or neither.
    # for directory based copies, just copy everything from the
    # temporary directory to the destination one, unless the destination
    # IS the temporary directory
    my $attach;
    if ($email!~/@/)
    {
      # Remember, '$outputFile' is what we return to the user...
      # If output directory is NOT a directory, take the basename as the prefix
      # instead of the PID since that's how the file was created in the first place.
      $email=~s/$sep$//;    # trim trailing separator in case specified
      my $prefix=(-d $email) ? $$ : basename($email);
      $outputFile="$tempdir$prefix-*";

      # If a PDF it has already been created by GS using the name '/tmp/$$-colplot.pdf'
      # and won't pass the test below so we need move it to 'prefix-colplot.pdf' in
      # the appropriate directory (or just rename it if in temp)
      if (!-d $email && $filetype eq 'pdf')
      {
        $command="$copy $pdfFile $email-colplot.pdf";
        displayText($mycfg, "Command: $command")    if $debug & 1;
        `$command`;

        $command="$del $pdfFile";
        displayText($mycfg, "Command: $command")    if $debug & 1;
        `$command`;
      }

      # If we're not writing to the temp directory, we need to copy the file(s) from temp
      # where they're initially written, to their ultimate destination
      elsif ((-d $email && $email ne $temp) || (!-e $email && dirname($email) ne $temp))
      {
        # if the destination is not a directory name, we need to pull that out first
        my $dirname=(-d $email) ? $email : dirname($email).$sep;
	$outputFile="$dirname$sep$prefix-*";
        $command="$copy $tempdir$sep*$prefix-* $dirname";
        displayText($mycfg, "Command: $command")    if $debug & 1;
        `$command`;

        $command="$del $tempdir$sep*$prefix-*";
        displayText($mycfg, "Command: $command")    if $debug & 1;
        `$command`;
      }
    }
    else    # Remember - this is UNIX only...
    {
      # we always tar up png files before mailing them
      my $tarname="$tempdir$$-colplot.tar";
      if ($filetype eq 'png')
      {
        $command="cd $tempdir; $mycfg->{TAR} -cf $tarname $$-*";
        displayText($mycfg, "Command: $command")    if $debug & 1;
        `$command`;
        $attach="$tarFile";
      }
      else
      {
        # if attaching the control file send both as a tar file, other wise
        # send pdf as single attachment
        $attach=$pdfFile;
        if ($pparams->{incctl})
        {
          $command="cd $tempdir; $mycfg->{TAR} -cf $tarname $$-*";
          displayText($mycfg, "Command: $command")    if $debug & 1;
          `$command`;
          $attach="$tarname";
        }
      }
      $outputFile=$attach;
    }
  }
  return($outputFile);
}

########################################################
#    B u i l d    A    P N G    F i l e
########################################################

sub buildPngPlot
{
  my $mycfg=  shift;
  my $pparams=shift;
  my $qString=shift;

  my $debug=   $mycfg->{debug};
  my $sep=     $mycfg->{sep};

  displayText($mycfg, "buildPngPlot -- QString: $qString")    if $debug & 16;

  my $filters='';
  my ($filename, $plots);

  $pparams->{uitype}=1;
  foreach my $arg (split(/&/, $qString))
  {
    next    if $arg eq '';

    $arg=~s/%([\dA-Fa-f][\dA-Fa-f])/pack('C', hex($1))/eg;

    my ($name, $value)=split(/=/, $arg, 2);      # in case value contains '='
    $arg=~s/\+/ /g    if $name ne 'filename';    # allow + in filename
    displayText($mycfg, "Name: $name  Value: $value")    if $debug & 1;

    $filename=  $value   if $name=~/filename/;
    $plots=     $value   if $name=~/plots/;
    my $filters=$value   if $name=~/filters/;

    $pparams->{mode}=$value        if $name=~/^mode/;
    $pparams->{plottype}=$value    if $name=~/^type/;
    $pparams->{tdate}=$value       if $name=~/^tdate/;
    $pparams->{ftime}=$value       if $name=~/^ftime/;
    $pparams->{ttime}=$value       if $name=~/^ttime/;
    $pparams->{datefix}=$value     if $name=~/^datefix/;
    $pparams->{timeframe}=$value   if $name=~/^timeframe/;
    $pparams->{winsize}=$value     if $name=~/^winsize/;
    $pparams->{width}=$value       if $name=~/^width/;
    $pparams->{height}=$value      if $name=~/^height/;
    $pparams->{thick}=$value       if $name=~/^thick/;
    $pparams->{legend}=$value      if $name=~/^legend/;
    $pparams->{adjust}=$value      if $name=~/^adjust/;
    $pparams->{xaxis}=$value       if $name=~/^xaxis/;
    $pparams->{pagbrk}=$value      if $name=~/^pagbrk/;
    $pparams->{xtics}=$value       if $name=~/^xtics/;
    $pparams->{ylog}=$value        if $name=~/^ylog/;
    $pparams->{email}=$value       if $name=~/^email/;
    $pparams->{filetype}=$value    if $name=~/^filetype/;
    $pparams->{incctl}=$value      if $name=~/^incctl/;
    $pparams->{subject}=$value     if $name=~/^subj/;
    $pparams->{filters}=$value     if $name=~/^filters/;
    $pparams->{instance}=$value    if $name=~/^instance/;
    $pparams->{contains}=$value    if $name=~/^contains/;
    $pparams->{unique}=$value      if $name=~/^unique/;
    $pparams->{anyall}=$value      if $name=~/^anyall/;
    $pparams->{oneperday}=$value   if $name=~/^oneperday/;
    $pparams->{yminwidth}=$value   if $name=~/^yminwidth/;
  }

  # since we have the name of the file we want to plot against OR in the case of mulitple
  # files it's the first in the range, we can reset the starting date to that file's date.
  $filename=~/-(\d{8})[-.]/;
  $pparams->{fdate}=$1;

  # We need to discover ALL the files that match this particular specification.
  my ($dir, $basename, $prefix, $ext);
  $dir=dirname($filename);
  $basename=basename($filename);
  $basename=~/(.*)-\d{8}.*?\.(.*)$/;
  $prefix=$1;
  $ext=$2;
  $ext=~s/\.gz$//;

  # This populates $allplots with the names/headers of all the files associate with this
  # one png file that's to be generated for this particular plot.  It always succeeds...
  my $selected={};
  findFiles(2, $mycfg, $pparams, "$dir$sep$prefix*.$ext", $selected);
  showSelected($mycfg, 'From BldPng 1', $selected, 1)    if $debug & 32;

  my $config={};
  initParamsInit($mycfg, $config);

  # right now, '$selected' is pointing to one or more files that match the selection criteria,
  # but by definition we only want to generate a single plot and that would be against the
  # first file.  If -oneperday has not been selected, all the matching files would be turned into
  # a single plot and so we need successive calls to initParams() to get the headers/plotting
  # params for each.  But now for some additional 'magic'!  If we're doing a detail plot, we only
  # want the plotting parameters that match the associater instance, so by setting the filter to
  # the correct instance, that's what we get.  Pretty slick, huh?
  my $globinfo={};
  my $date=$pparams->{fdate};
  my $allplots=$selected->{$ext}->{$prefix}->{$date};
  my $select={plots=>$plots, filters=>$pparams->{instance}};
  $select->{plottype}=$pparams->{plottype}
	if defined($pparams->{plottype}) && $pparams->{plottype}!~/default/i;

  for (my $i=0; $i<scalar(@$allplots); $i++)
  {
    my $plotinfo=[];
    my $hdrref= \$allplots->[$i]->{header};
    my $filename=$allplots->[$i]->{fullname};
    $select->{filename}=$filename;    # for debugging

    # For special lustre handling
    $select->{fileinfo}->{lusclt}=$allplots->[$i]->{lusclt};
    $select->{fileinfo}->{lusmds}=$allplots->[$i]->{lusmds};
    $select->{fileinfo}->{lusoss}=$allplots->[$i]->{lusoss};

    # As when we build a page (only this can happen a little more often), if a specific plot
    # doesn't exist for a specific file, remove that file from selection list.
    my $number=initParams($mycfg, $config, $select, $hdrref, $plotinfo, $globinfo);
    if ($number==0)
    {
      displayText($mycfg, "Delete Selection selected->{$ext}->{$prefix}->{$date}->[$i]")
		if $debug & 32;
      delete $selected->{$ext}->{$prefix}->{$date}->[$i];
      next;
    }

    showParams($mycfg, $plotinfo, $filename)    if $pparams->{showparams};
    $allplots->[$i]->{plotinfo}=$plotinfo;
  }
  showSelected($mycfg, 'From BldPng 2', $selected, 2)    if $debug & 32;

  # We need to know how many days this plot spans and remember that {dayspan} simply
  # reports the number of days spanned until the current entry, so to find total we need to
  # look at LAST entry,
  my $context={};
  $context->{state}=1;
  $context->{plotnum}=0;
  $context->{dayspan}=$allplots->[scalar(@$allplots)-1]->{dayspan};

  # If this plot has a specific instance, pass it along as a separate param even though in pparms
  # because that argument to plotit() triggers special processing
  my $pngFile=plotit($mycfg, $context, $pparams, $allplots, $globinfo, 0, $pparams->{instance});
  return($pngFile);
}

####################################################################
#    I n i t i a l i z e    P l o t t i n g     P a r a m e t e r s
####################################################################

# This loads the plotting tables into a data structure.
sub initParams
{
  my $mycfg=  shift;
  my $cfgref= shift;
  my $select= shift;
  my $hdrref= shift;
  my $plotref=shift;
  my $globref=shift;

  my $debug=$mycfg->{debug};

  # NOTE - filename only being passed as a debugging aid
  my $plots=   defined($select->{plots})       ? $select->{plots}    : '';
  my $filters= defined($select->{filters})     ? $select->{filters}  : '';
  my $filename=defined($select->{filename})    ? $select->{filename}  : '';
  my $plottype=defined($select->{plottype})    ? $select->{plottype}  : '';
  displayText($mycfg, "InitParams -- File: $filename  Plots: $plots  Filters: $filters")    if $debug & 16;

  #############################################################
  # STEP 1 - build array and hash of all plots selected via -p
  #############################################################

  displayText($mycfg, "IP: Step 1")     if $debug & 2;

  # We want to preserve the order of the plots selected
  my @plots;
  my $index=0;
  foreach my $plot (split(/[, ]+/, $plots))
  {
    liberror($mycfg, "invalid plot name '$plot'")    if !defined($cfgref->{AllPlots}->{$plot});
    $plots[$index++]=$plot;
  }

  #########################################################
  #  STEP 2 - Make sure all fields defined for ALL plots
  #########################################################

  # Not all fields are required and if left out initialize them as appropriate
  displayText($mycfg, "IP: Step 2")     if $debug & 2;

  foreach my $plot (@plots)
  {
    $cfgref->{AllPlots}->{$plot}->{mask}=0       if !defined($cfgref->{AllPlots}->{$plot}->{mask});
  }

  ##########################################################
  # STEP 3 - Initialize Hash with Column Names/Numbers
  ##########################################################

  displayText($mycfg, "IP: Step 3")     if $debug & 2;

  my %colNames;
  my $firstCol='';
  my ($colNum, $instNum)=(0,0);
  displayText($mycfg, "Header: $$hdrref")    if $debug & 2;

  my $sep=substr($$hdrref,5,1);
  foreach my $colName (split(/$sep/, $$hdrref))
  {
    next    if $colName=~/^#Date|^Time/;

    $colNames{$colName}=$colNum;
    $colNum++;
  }

  ######################################################
  # STEP 4 - Build plotting array & Instance Processing
  ######################################################

  displayText($mycfg, "IP: Step 4 - NumInstances: $instNum")     if $debug & 2;

  my ($instFlag, $plot);
  for (my $plotnum=0; $plotnum<scalar(@plots); $plotnum++)
  {
    $plot=$plots[$plotnum];
    my $mask=$cfgref->{AllPlots}->{$plot}->{mask};

    # Pull out the first column name for this plot, including leading '['.
    $cfgref->{AllPlots}->{$plot}->{yname}=~/(\[.*?)\]/;
    my $ynameTag=quotemeta($1);

    # Very special case that MAY have to be enhanced.  The underlying design
    # philosophy is that if any plot's field qualifier exists in the header
    # the field name itself must too.  In the case of data generated by collectl
    # this is absolutely true.  BUT if that data file were generated elsewhere
    # that might not be the case and this is particularly true for memory data
    # which can contain various types of fields and hence plots.  Best example
    # is fault data which may not always be present.  For now I'm limiting the
    # test to MEM data to minimize the overhead but if other types prove a
    # problem this may have to be expanded...
    if ($cfgref->{AllPlots}->{$plot}->{mask} & 16)
    {
      my $found=0;
      foreach my $yname (split(/,/, $cfgref->{AllPlots}->{$plot}->{yname}))
      {
        if (defined($colNames{$yname}))
        {
          $found=1;
	  last;
	}
      }
      displayText($mycfg, "No data fields found in header for '$plot'")    if $debug & 1  && !$found;
      next    if !$found;
    }

    # sigh, another special case for lustre!  If someone had generated a 'tab' file
    # using -L to force data for non-present subsystems, we get columns which will
    # have no data and that will then cause plots to appear with no data in them
    # which can be annoying.  Therefore make sure there is REAL data present.
    if ($filename=~/tab$/)
    {
      next    if $ynameTag=~/CLT/ && !$select->{fileinfo}->{lusclt};
      next    if $ynameTag=~/MDS/ && !$select->{fileinfo}->{lusmds};
      next    if $ynameTag=~/OSS/ && !$select->{fileinfo}->{lusoss};
    }

    # If the tag isn't in the header, we can't select this plot for this file.
    # If it IS there, see what follows and if something there, we have instance
    # data.  Note that there are usually more than one instance names and so we
    # will need to find all of them later on.
    if ($$hdrref!~/$ynameTag(.*?)\]/)
    {
      displayText($mycfg, "No data fields found in header of '$filename' for '$plot'")    if $debug & 32;
      next;
    }

    $instFlag=($1 eq '' || $mask & 8) ? 0 : 1;
    displayText($mycfg, "Plot: '$plot'  InstFlag: $instFlag  1st InstName: $1")    if $debug & 64;

    my $instList='';
    $cfgref->{AllPlots}->{$plot}->{yname}=~/(\[.*?)\]/;
    my $headerTag=$1;

    # Processing for files with instance data
    if ($instFlag)
    {
      # loop though ALL headers looking for unique instance names and save for later.
      # Since the header contains special chars (like '[' and who knows what else!),
      # we need to quote them
      my $metaTag=quotemeta($headerTag);

      my $cpuFlag=0;
      my %instances;
      foreach my $colName (keys %colNames)
      {
        # We need column name up to but NOT including the ']' and everything that follows
        # In some cases we can have mixed instance names for compound data, so ignore those
        # that don't match the one we're looking for.  We also need to know if CPU data for
        # instance sorting later

        $colName=~s/\].*//;
        next          if $colName!~/$metaTag/;
        $cpuFlag=1    if $colName=~/CPU/;

        # Pull out instance piece, which we know IS there, and build up a list of all
        # unique instance names for later.
        $colName=~/$metaTag(.*)/;
        my $inst=$1;

        # This gives us a hash of each unique instance
        $instances{$inst}=0;
      }
      # now we build a string of all the instances in the appropriately sorted order
      my @sorted=($cpuFlag) ? (sort {$a <=> $b} keys %instances) : (sort keys %instances);
      foreach my $inst (@sorted)
      { $instList.="$inst "; }
      $instList=~s/ $//;
      displayText($mycfg, "InstList: $instList  Filters: $filters")    if $debug & 64;

      # Filtering is actually a 2-step process.  First we process all the filters, only keeping those
      # that apply to our instance names.  Then, and only then, do we filter out those that don't
      # match this new (sub)set of filters.
      if ($filters ne '')
      {
        my $newFilters='';
        foreach my $filter (split(/[, ]/, $filters))
        {
          # CPU filters are special because they're numeric and can be in the form of a range
	  if ($cpuFlag && $filter=~/^\d+\-\d+$/)
	  {
	    # first convert xx-yy to xx..yy so we can eval it into an array
	    $filter=~s/-/../;
	    my @cpus=eval("($filter)");

	    # now reset the current value of $filter to a | separated list
	    # so the append below works out correctly
	    $filter='';
	    foreach my $cpu (@cpus)
	    { $filter.="$cpu|"; }
	    $filter=~s/\|$//;
	  }
	  $newFilters.="$filter "    if $instList=~/$filter/;
        }
        $newFilters=~s/ $//;

        my $temp='';
        foreach my $inst (split(/ /, $instList))
        {
          my $match=0;
          foreach my $filter (split(/ /, $newFilters))
          {
            $match=1    if $inst=~/$filter/;
          }
          $temp.="$inst "    if $match;
        }
        $temp=~s/ $//;
        $instList=$temp;
      }

      # Put ']' back on for consistency, though I'm not even sure if we need to save it!
      my $headerTag.=']';
    }
    displayText($mycfg, "Plot: $plot  Tag: $headerTag  After Filters: $instList")    if $debug & 64 && $instFlag;

    my $instance='';
    my @instances=split(/ /, $instList);
    for (my $i=0; !$instFlag || $i<scalar(@instances); $i++)
    {
      $instance=(!$instFlag) ? '' : $instances[$i];

      # A bit of brute force here to make life easier.  In the case of divisors of 1024, we've
      # appended KB or MB to the legend, but we haven't done anything when dividing by 1000!
      # I'm also not sure what to put in the legend so instead I'm going to append ' (1000s)' to
      # the plot title, but only if all divisors are the same.
      my $lastDiv;
      my $diffDiv=0;
      my $titleMod='';
      foreach my $div (split(/,/, $cfgref->{AllPlots}->{$plot}->{ydivisor}))
      {
        $lastDiv=$div    if !defined($lastDiv);
        $diffDiv=1       if $lastDiv!=$div;
      }
      $titleMod=" (${lastDiv}s)"    if !$diffDiv && $lastDiv>1 && $lastDiv=~/000$/;

      # These are the complete parameters for each plot, each probably comma separated
      # for multiple lines.
      push @$plotref, {
            PlotName => $plot,
	    HeaderTag=> $headerTag,
            InstName => $instance,
            Mask     => $cfgref->{AllPlots}->{$plot}->{mask},
            Name     => $cfgref->{AllPlots}->{$plot}->{title}.$titleMod,
            PType    => $cfgref->{AllPlots}->{$plot}->{ptype},
            YNameStr => $cfgref->{AllPlots}->{$plot}->{yname},
            YLabelStr=> $cfgref->{AllPlots}->{$plot}->{ylabel},
            CLabelStr=> $cfgref->{AllPlots}->{$plot}->{clabels},
            YMinStr  => $cfgref->{AllPlots}->{$plot}->{ymin},
            YMaxStr  => $cfgref->{AllPlots}->{$plot}->{ymax},
            YDivStr  => $cfgref->{AllPlots}->{$plot}->{ydivisor},
            Operators=> $cfgref->{AllPlots}->{$plot}->{oper}
	 };

       # if we're not doing instance data, we only make a single pass through here
       last    if !$instFlag;
    }
  }

  ##########################################################
  # STEP 5 - fill in defaults for any missing fields and
  #          most important, fill in column numbers
  ##########################################################

  my ($rectFlag, $radialFlag, $yMajWidth, $yMinWidth, $yMaxAxes)=(0,0,0,0,0);
  for (my $i=0; $i<scalar(@$plotref); $i++)
  {
    # We can have holes in our structure if no data for a particular plot
    next    if !defined(@$plotref[$i]);

    # We may want to know if any radial OR rectangular plots
    @$plotref[$i]->{PType}=$plottype    if $plottype ne '';
    $rectFlag=1                         if @$plotref[$i]->{PType}!~/r/;
    $radialFlag=1                       if @$plotref[$i]->{PType}=~/r/;

    @$plotref[$i]->{YMinStr}=0          if !defined(@$plotref[$i]->{YMinStr});
    @$plotref[$i]->{YDivStr}=1          if !defined(@$plotref[$i]->{YDivStr});

    my @headers=split(/,/, @$plotref[$i]->{YNameStr});
    my $numCols=scalar(@headers);

    @$plotref[$i]->{YMinStr}=  propogate($mycfg, $numCols, 'YMin',  @$plotref[$i]->{YMinStr});
    @$plotref[$i]->{YMaxStr}=  propogate($mycfg, $numCols, 'YMax',  @$plotref[$i]->{YMaxStr});
    @$plotref[$i]->{YDivStr}=  propogate($mycfg, $numCols, 'YDiv',  @$plotref[$i]->{YDivStr});
    @$plotref[$i]->{YLabelStr}=propogate($mycfg, $numCols, 'Labels',@$plotref[$i]->{YLabelStr});

    @$plotref[$i]->{YNames}= [split(/,/, @$plotref[$i]->{YNameStr})];
    @$plotref[$i]->{YLabels}=[split(/,/, @$plotref[$i]->{YLabelStr})];
    @$plotref[$i]->{YMin}=   [split(/,/, @$plotref[$i]->{YMinStr})];
    @$plotref[$i]->{YMax}=   [split(/,/, @$plotref[$i]->{YMaxStr})];
    @$plotref[$i]->{YDiv}=   [split(/,/, @$plotref[$i]->{YDivStr})];
    @$plotref[$i]->{Oper}=   [split(/,/, @$plotref[$i]->{Operators})];

    #    F i l l    I n    C o l u m n    N u m b e r s

    my $matchFlag=0;
    for (my $j=0; $j<scalar(@{@$plotref[$i]->{YNames}}); $j++)
    {
      my $colName= @$plotref[$i]->{YNames}->[$j];
      my $instance=@$plotref[$i]->{InstName};
      my $mask=    @$plotref[$i]->{Mask};
      $colName=~s/\]/$instance]/;

      # If we can't find column header we must be looking at wrong file for this plot
      # unless of course we're dealing with constants or a mask of 2!!!
      my $colNumber=defined($colNames{$colName}) ? $colNames{$colName} : -1;
      displayText($mycfg, "Column: $colName  Inst: $instance  Number: $colNumber  Mask: $mask")    if $debug & 2;
      liberror($mycfg, "can't find column name '$colName' for plot @$plotref[$i]->{PlotName} in '$filename' header!")
	if !($mask & 2) && $colNumber==-1 && $colName!~/^\d+[KMG]*$/;

      @$plotref[$i]->{YColnum}->[$j]=$colNumber;
      $matchFlag++    if $colNumber!=-1;    # Track plots with at least 1 matching column
    }

    # If we didn't find any columns matching a particular plot entry (eg when you
    # you have an entry for a 'temp' plot, a 'speed' column will never match!)
    # remove the entire plot entry.  On the the other hand if doing temp and speed,
    # the temp column will match the temp plot but not the speed one but that's ok
    # because we catch it when actually building the column specs in the gnuctl file.
    if (!$matchFlag)
    {
      delete @$plotref[$i]   if !$matchFlag;
      next if !$matchFlag;
    }

    #    P r o c e s s    M u l t i p l e    Y - A x i s

    my (@yMinLabel, @yMaxLabel, $lastYMin, $lastYMax);
    undef @yMinLabel;
    undef @yMaxLabel;
    $lastYMin=$lastYMax=-1;
    for (my $j=0; $j<scalar(@{@$plotref[$i]->{YLabels}}); $j++)
    {


      # Every time ymin or ymax changes, we generate a new pair of axis limits
      # Also keep track of the maximum width for labels.
      if ((@$plotref[$i]->{YMin}->[$j]!=$lastYMin) || (@$plotref[$i]->{YMax}->[$j]!=$lastYMax))
      {
        push @yMinLabel, @$plotref[$i]->{YMin}->[$j];
        push @yMaxLabel, @$plotref[$i]->{YMax}->[$j];

        # we need the max widths for ALL plots for both the Y major and
        # Y minor axis
        $yMajWidth=length(@$plotref[$i]->{YMax}->[$j])
                if $j==0 && $yMajWidth<length(@$plotref[$i]->{YMax}->[$j]);
        $yMinWidth=length(@$plotref[$i]->{YMax}->[$j])
                if $j!=0 && $yMinWidth<length(@$plotref[$i]->{YMax}->[$j]);

        $lastYMin=@$plotref[$i]->{YMin}->[$j];
        $lastYMax=@$plotref[$i]->{YMax}->[$j];
      }
      @$plotref[$i]->{YMinLabel}=[@yMinLabel];
      @$plotref[$i]->{YMaxLabel}=[@yMaxLabel];

      my $numAxes=scalar(@yMinLabel);
      $yMaxAxes=$numAxes    if $numAxes>$yMaxAxes;
    }
  }
  $globref->{ymaxaxes}=  $yMaxAxes;
  $globref->{ymajwidth}= $yMajWidth;
  $globref->{yminwidth}= $yMinWidth;
  $globref->{rectflag}=  $rectFlag;
  $globref->{radialflag}=$radialFlag;
  displayText($mycfg, "Nothing matched in initParams()")    if $debug & 1 && scalar(@$plotref)==0;
  return(scalar(@$plotref));
}

sub propogate
{
  my $mycfg=  shift;
  my $numCols=shift;
  my $descr=  shift;
  my $entry=  shift;
  my (@temp, @names, $last, $temp2);

  @temp=split(/,/, $entry);
  $last=$temp2=$temp[0];
  liberror($mycfg, "First column data not specified for '$descr'")   if !defined($last);
  for (my $i=1; $i<$numCols; $i++)
  {
    # Remember 1st column never blank, that's why we started at 1.
    $temp[$i]=$temp[$i-1]     if !defined($temp[$i]) || $temp[$i] eq '';
    $temp2.=sprintf(",%s", $temp[$i]);
  }
  return($temp2);
}

# This is a 'helper' routine for buildPage in an attempt to keep it less cluttered.
sub genhrefs
{
  my $mycfg=     shift;
  my $hrefs=     shift;
  my $pparams=   shift;
  my $allplots=  shift;
  my $firstIndex=shift;
  my $plotIndex= shift;

  my $plotinfo=$allplots->[$firstIndex]->{plotinfo}->[$plotIndex];
  my $debug=$mycfg->{debug};
  print "GenHref - FirstIndex: $firstIndex  PlotIndex: $plotIndex  Filename: $allplots->[$firstIndex]->{fullname}  Plot: $plotinfo->{PlotName}\n"
	if $debug & 2;

  my $href='';
  $href.="&filename=". $allplots->[$firstIndex]->{fullname};
  $href.="&plots=".    $plotinfo->{PlotName};
  $href.="&instance=". $plotinfo->{InstName};
  $href.="&type=".     $plotinfo->{PType};

  # User Specified Parameters.  Funky syntax allows me to line up '$pparams's
  # NOTE that we're always going to generate 'png' files and that the current value
  # of 'filetype' is still set to the screen default of 'pdf', so force it to 'png'
  $href.="&filetype=". 'png';
  $href.="&mode=".     $pparams->{mode};
  $href.="&legend=".   $pparams->{legend};
  $href.="&adjust=".   $pparams->{adjust};
  $href.="&xaxis=".    $pparams->{xaxis};
  $href.="&fdate=".    $pparams->{fdate};
  $href.="&tdate=".    $pparams->{tdate};
  $href.="&ftime=".    $pparams->{ftime};
  $href.="&ttime=".    $pparams->{ttime};
  $href.="&timeframe=".$pparams->{timeframe};
  $href.="&winsize=".  $pparams->{winsize};
  $href.="&width=".    $pparams->{width};
  $href.="&height=".   $pparams->{height};
  $href.="&thick=".    $pparams->{thick};
  $href.="&contains=". $pparams->{contains};
  $href.="&anyall=".   $pparams->{anyall};
  $href.="&subject=".  $pparams->{subject};      #<<<<<<<<<<<<< this is here for api experiments since plotting doesn't need subj
  $href.="&oneperday=".$pparams->{oneperday}     if $pparams->{oneperday};
  $href.="&unique=".   $pparams->{unique}        if $pparams->{unique};
  $href.="&xtics=".    $pparams->{xtics}         if $pparams->{xtics}>0;
  $href.="&ylog=".     $pparams->{ylog}          if $pparams->{ylog} eq 'on' ;
  $href.="&yminwidth=".$pparams->{yminwidth}     if $pparams->{yminwidth};
  push @$hrefs, $href;

  # If set, print on tty for remote generation of hrefs
  print "$href\n"    if $pparams->{href};
}

#    G e n e r a t e   P L O T S

# This routine is responsible for building a gnu control file and executing it.
# Where the output goes is controlled by a multitude of parameters.  It is actually
# a 'helper' function called by both 'buildPage()' and 'buildPngPlot()'
sub plotit
{
  my $mycfg=    shift;
  my $context=  shift;
  my $pparams=  shift;
  my $allplots= shift;
  my $globinfo= shift;
  my $plotIndex=shift;
  my $instName= shift;

  $instName=''    if !defined($instName);

  # First thing, set up environment.  These are constants that must be initialized
  # by the caller since we really don't want to do this for every call to us.
  my $debug=   $mycfg->{debug};
  my $pcFlag=  $mycfg->{pcflag};
  my $tempDir= $mycfg->{tempdir};
  my $quote=   $mycfg->{quote};
  my $gnuver=  $mycfg->{GnuVersion};
  my $htmlFlag=$mycfg->{htmlflag};
  my $sep=     $mycfg->{sep};

  my $gnuCtlFile="$tempDir$$-colplot.ctl";
  my $pdfFile=   "$tempDir$$-colplot.pdf";
  my $psFile=    "$tempDir$$-colplot.ps";

  # EXPERIMENTAL API - one time intialization
  my ($apiInit, $apiCommands, $apiParams);
  if ($pparams->{subject}=~/API:(.*)/)
  {
    my ($apiBase, $params)=split(/,/, $1, 2);
    $apiBase=~s/\.ph//;
    $apiParams=$params;

    no strict 'refs';
    require "$apiBase.ph";

    $apiBase=basename($apiBase);
    $apiInit=    "${apiBase}InitParams";
    $apiCommands="${apiBase}Commands";
  }

  #    C l e a n u p

  # Move terminal/pdf into genpage?
  if ($context->{state}==3)
  {
    if ($pparams->{filetype}=~/term|pdf/)
    {
      # Both terminal output and pdfs get rendered here.  PNG output gets rendered
      # inside of plotit() since you need one call to gnuplot/plot.
      # For terminal-based plotting, this means finish off 'ctl' file first.
      if ($pparams->{filetype}=~/term/)
      {
        print INI "set nomultiplot\n";
        print INI "pause -1 \"Type RETURN to finish\"\n";
      }
      close INI;

      # Render plot on terminal OR generate a PS file (which gets converts to PDF below).
      # NOTE - with V4 of gnuplot we get warnings when using multiplot and one fix was to
      #        redirect output to /dev/null, but then we miss the "press reurn..." msg
      my $command="$quote$mycfg->{GnuPlot}$quote $gnuCtlFile";
      displayText($mycfg, "Command: $command")    if $debug & 1;
      `$command`;
      unlink $gnuCtlFile    unless $debug & 4 || $pparams->{incctl};

      # If doing pdf, we currently have a temporary 'ps' file, so convert it
      # NOTE - if we make unlink conditional on debug=4, that file gets included
      # in attachments and it just makes thing messier!
      if ($pparams->{filetype} eq 'pdf')
      {
        $command="$mycfg->{GS} -sDEVICE=pdfwrite -sOutputFile=$pdfFile -dNOPAUSE -dBATCH $psFile";
        displayText($mycfg, "Command: $command")    if $debug & 1;
        `$command`;
        unlink $psFile;
      }
      $context->{state}=1;
    }
    elsif ($pparams->{filetype}=~/png|tty/)
    {
      # For png files (which includes those going to terminal) just close the INI file.
      close INI;
    }
    return(1);
  }

  #    N o r m a l    P r o c e s s i n g

  # Note that when called with state==3, we don't get 'allplots' passed to us so we can't do this
  # until now.  Also note that we don't necessarily start plotting against the first file passed to
  # us (thought we ALMOST ALWAYS do) so we need to find the first entry with valid plotting data.
  # Also remember - %allplots contains all plots for THIS particular selection (run with debug & 32)

  if ($debug & 16)
  {
    my $text="PLOTIT -- State: $context->{state}  PlotNum: $context->{plotnum}  Type: $pparams->{filetype} Inst: $instName ";
    displayText($mycfg, $text);
  }

  # We're getting called with 'plotIndex' which points to the plotting info we're to use and if we have
  # multiple files it applies to all. However sometimes we don't have any data for the very first and/or
  # last file and so we need to figure out where to start/stop each individual plot.
  my ($firstIndex, $lastIndex, $plotinfo, $filename, $lastInst);
  for (my $fileIndex=0; $fileIndex<scalar(@$allplots); $fileIndex++)
  {
    my $tempinfo=$allplots->[$fileIndex]->{plotinfo};
    if (defined($tempinfo->[$plotIndex]->{PlotName}))
    {
      $lastIndex= $fileIndex;
      $firstIndex=$fileIndex    if !defined($firstIndex);
    }

    # if instance plotting the last file is not necessarily the same as the last one with data, we
    # reset the index accordingly
    if ($instName ne '' && defined($tempinfo))
    {
      foreach (my $pi=0; $pi<scalar(@$tempinfo); $pi++)
      {
        $lastInst=$fileIndex    if $tempinfo->[$pi]->{InstName} eq $instName
      }
    }
  }

  # If no files contain plotting info just return, but we need to do it this way so we can
  # include debugging info or I'll never be able to debug this!
  if (!defined($firstIndex))
  {
    print "No data for plot $plotIndex\n"    if $debug & 1;    # and we don't even know plot's name!
    return(0);
  }

  # Remember, $firstIndex points to the file we want to start processing but $plotIndex points to the
  # plotting data for a particular plot
  $plotinfo=$allplots->[$firstIndex]->{plotinfo};
  $filename=$allplots->[$firstIndex]->{fullname};
  my $mask=$$plotinfo[$plotIndex]->{Mask};
  if ($debug & 16)
  {
    my $temp=sprintf("%8s  PlotIndex: %d First: %d Last: %d  File: %s Plot: %s LastInst: %s Mask: %d\n",
			'', $plotIndex, $firstIndex, $lastIndex, $filename, $plotinfo->[$plotIndex]->{PlotName},
			$instName ne '' ? $lastInst : '', $mask);
    displayText($mycfg, $temp);
  }

  my $email=    $pparams->{email};
  my $filetype= $pparams->{filetype};
  my $width=    $pparams->{width};
  my $height=   $pparams->{height};
  my $thick=    $pparams->{thick};
  my $pdfFlag=(defined($email) && $pparams->{filetype} eq 'pdf') ? 1 : 0;

  # get the file's base name (no directory info) as well as root (not even the extension).
  my ($basename, $prefix, $fileroot);
  $basename=$prefix=$fileroot=basename($filename);
  $prefix=~s/-\d{8}.*//;
  $fileroot=~s/\..*$//;

  # get png file name from base of data file name and convert to lower case just because
  # it looks nicer when used in a filename.
  my $plot=lc($plotinfo->[$plotIndex]->{PlotName});

  # special stuff - if the user specifies an output filename of /dir/xxx, the
  # xxx will be taken as an explict prefix instead of the PID
  my $pfx=(defined($email) && $email ne '' && $email!~/@/ && !-d $email) ? basename($email) : $$;
  my $pngFile="$tempDir$pfx-$fileroot-$plot.png";
  unlink $pngFile;

  # More trickery - if any of the plots use a second axis we need to set one for all
  # of them so they end up with the same width
  my $multiYFlag=0;
  for (my $i=0; $i<scalar(@$plotinfo); $i++)
  {
    next    if !defined($plotinfo->[$i]->{YMaxLabel});
    $multiYFlag=1    if scalar(@{$plotinfo->[$i]->{YMaxLabel}})>1;
  }

  # $y2Width defines the maximum size of ALL y2 axes and also serves as a flag to tell us
  # if there are any.  $numAxes on the other hand tells us how many axes THIS specific
  # plot has.  If >1, it has at least 2.
  my $y2Width=$pparams->{yminwidth};
  my $numAxes=scalar(@{$plotinfo->[$plotIndex]->{YMaxLabel}});
  #displayText($mycfg, "y2Width: $y2Width  NumAxes: $numAxes");

  #    S t a r t    A    N e w    O u t p u t    F i l e  ?

  # There are 2 cases where we need a NEW ctl file
  # At least for we're lumping 'tty' in with png because we only do 1 tty file at a time
  # Even though we should NOT have more than one tty, if we do we'll end up trying to
  # write on a close ctl file!
  my $color;
  if ($context->{state}==1 || $pparams->{filetype}=~/png|tty/)
  {
    displayText($mycfg, "Creating gnuctl file: $gnuCtlFile")    if $debug & 1;
    open INI, ">$gnuCtlFile" or liberror($mycfg, "Couldn't open '$gnuCtlFile' for appending");

    #                    >>>>  NOTE  <<<
    # the numbers/configuration that follow have been arrived at my trial
    # and error and seemed to look good at the time.  Your mileage may vary!

    # If we have a minor Y axis, we need more space in the right margin above and
    # beyond 15 which is our default.
    my $rm=15;
    $rm+=$pparams->{yminwidth}    if defined($pparams->{yminwidth});
    print  INI "set lmargin 8\n";
    printf INI "set tmargin %d\n", $pparams->{filetype}=~/term/ ? 1 : 1;    # need at least 1 for title
    printf INI "set rmargin %d\n", $pparams->{legend}=~/on/i ? $rm : 1;
    printf INI "set bmargin %d\n", $pparams->{xaxis}=~/on/i ? 2 : 0;        # need 2 for axis

    # Time for gnuplot V4 specifics - can you believe they changed the syntax!!!  8-(
    my $linestyle;
    if ($gnuver<4)
    {
      $linestyle="linestyle";
      $color="color";
    }
    else
    {
      $linestyle="style line";
      $color="";
    }

    my $pt=(@$plotinfo[$plotIndex]->{PType}=~/l/) ? 0 : $thick-1;
    for (my $i=1; $i<=16; $i++)
    {
      print  INI "set $linestyle $i lt $mycfg->{'lt'.$i} lw $thick pt $pt ps 1.0\n";
    }

    # NOTE - 'set ticscale' syntax changes at V4.2!
    printf INI "set %s -0.4 -0.2\n", $mycfg->{GnuVersion}>=4.2 ? 'tics scale' : 'ticscale';
    print  INI "set border 15 linewidth 0.2\n";

    my $timefmt="%Y%m%d %H:%M:%S";
    my $ylog= $pparams->{ylog};
    print   INI "set xdata time\n";
    print   INI "set timefmt \"$timefmt\"\n";
    print   INI "set logscale y\n"     if defined($ylog) && $ylog=~/on/;

    # defaults for legend, noting 'vertical' was introduced with gnuplot 4.2
    my $legend=$pparams->{legend};
    my $vertical=($mycfg->{GnuVersion}>=4.2) ? 'vertical' : '';
    print  INI "set key top $vertical right outside Right samplen 1 spacing .7\n"
          if $pparams->{filetype}!~/term/ && $legend=~/on/;
    print  INI "set nokey\n"    if  $legend=~/off/i;

    if ($pdfFlag)
    {
      print INI "set terminal postscript landscape color solid \"courier\" 8\n";
      print INI "set output '$psFile'\n";
      print INI "set multiplot\n";
    }
    elsif ($pparams->{filetype}=~/term/)    # CLI
    {
      # We're overriding legend params and may want to make further changes
      # in the future.
      print INI "set key top right outside Right samplen 1 spacing 0.5\n"
            if $legend=~/on/;
      print INI "set multiplot\n";
    }

    if ($pparams->{subject}=~/API/ && defined(&$apiInit))
    {
      no strict 'refs';

      my $apiInitOutput=&$apiInit($mycfg, $pparams, $context, $apiParams);
      print INI $apiInitOutput;

      # in case API reset them
      $width= $pparams->{width};
      $height=$pparams->{height};
    }
  }

  #    F o r    E a c h    N E W    I n d i v i d u a l    P l o t

  #  my $mask=$$plotinfo[$plotIndex]->{Mask};

  # Plots that require displaying multiple plots (non web-based OR raw png output)
  # need to bracket each page by toggling the multiplot setting.
  # If starting a new page on the terminal, we also need to insert a pause...
  if ($filetype=~/term|pdf/ && $context->{state}==2 && $context->{plotnum}==1)
  {
    print INI "set nomultiplot\n";
    print INI "pause -1 \"Type RETURN to see next page\"\n"    if $pparams->{filetype}=~/term/;
    print INI "set multiplot\n";
  }

  # Since we can have multiple plots covering multiple days, we need to set
  # the right limits every time.  Note that the dates come from the first and
  # last filenames whether or not they're included in this particular plot or not.
  my ($fromTime, $thruTime, $fromDate, $thruDate);
  $fromTime=    $pparams->{ftime};
  $thruTime=    $pparams->{ttime};
  if ($pparams->{datefix} eq 'on')
  {
    $fromDate=$allplots->[$firstIndex]->{fullname};    # first one that exists
    $fromDate=~/-(\d{8})[.-]/;
    $fromDate=$1;
    $thruDate=$allplots->[$lastIndex]->{fullname};
    $thruDate=~/-(\d{8})[.-]/;
    $thruDate=$1;
  }
  else
  {
    $fromDate=$pparams->{fdate};
    $thruDate=$pparams->{tdate};
  }

  # If file from a different timezone, reset the from/thru times based on the difference
  my $tzone=$allplots->[$firstIndex]->{tzone};
  if ($pparams->{timeframe} eq 'float' && $tzone ne $mycfg->{tzone} )
  {
    # in 'float' mode, we MIGHT be looking at a file from another timezone [rare]
    # and since we've saved the timezone where it was generated, convert that to
    # secs which we will then use to get the range based on the local times
    if ($tzone ne $mycfg->{tzone})
    {
      # remember, the times are stored in UCT and ALWAYS of the form [-]HHMM
      $tzone=~/(.*)(\d{2})(\d{2})/;
      my $tzsign=($1 eq '-') ? '-' : '+';
      my $tzhour="$tzsign$2";
      my $tzmins="$tzsign$3";

      # this is the difference in secs of the remote timezone
      my $tzdiff=$tzhour*3600+$tzmins*60;
      my $window=$pparams->{winsize}*60;

      # convert the local thru time to the remote file's thru time in secs
      my $year=substr($thruDate, 0, 4);
      my $mon= substr($thruDate, 4, 2);
      my $day= substr($thruDate, 6, 2);
      my ($hour, $mins)=split(/:/, $thruTime);
      my $localSecs=timelocal(0, $mins, $hour, $day, $mon-1, $year-1900);

      # we need these to compute x-axis in the time where the data generated and so
      # add in the timezone difference but use gmtime() do it doesn't get converted
      my $locThruTime=$localSecs+$tzdiff;
      my ($fsecs, $fmins, $fhour, $fday, $fmon, $fyear)=gmtime($locThruTime-$window);
      $fromDate=sprintf("%d%02d%02d", $fyear+1900, $fmon+1, $fday);
      $fromTime=sprintf("%02d:%02d", $fhour, $fmins);

      my ($tsecs, $tmins, $thour, $tday, $tmon, $tyear)=gmtime($locThruTime);
      $thruDate=sprintf("%d%02d%02d", $tyear+1900, $tmon+1, $tday);
      $thruTime=sprintf("%02d:%02d:%02d", $thour, $tmins, $tsecs);
    }
  }
  print  INI "set xrange[\"$fromDate $fromTime\":\"$thruDate $thruTime\"]\n";

  # AXIS CONTROL
  # If visible, the format of the x-axis depends on how many days this plot spans!
  # also, for multiday plots, we only want a tic mark every day AND this overrides
  # any ticmark settings the user may have chosen too since they would make no sense.
  # Subtle - we're NOT going to set multiday if <25 hours (range not from 00:00-24:00)
  # becuase resultant plot looks ugly.
  # look
  my $multiday=((seconds($thruDate, $thruTime)-seconds($fromDate, $fromTime)) > 3600*24+60) ? 1 : 0;
  my $xformat=($multiday) ? '"%Y%m%d"' : '"%H:%M:%S"';
  my $xtics=  ($multiday) ? 86400 : $pparams->{xtics};
  printf  INI "set format x %s\n", $pparams->{xaxis}=~/on/i ? $xformat : '""';
  printf  INI "set xtics %s\n", $xtics ? $xtics : 'autofreq';
  print   INI "set format y \"%.1f\"\n"    if $mask & 32;
  print   INI "set y2tics\n"         if $numAxes>1;

  # If the plot has an instance name, include that as well, preceeded by a ':'
  # If a multiday plot, include the date in the title
  my $displayName=($pparams->{uitype}==1 && $pparams->{mode}=~/live/) ? $prefix : $basename;
  my $datemod=($fromDate eq $thruDate) ? '' : "->$thruDate";

  printf INI "set title \"$displayName$datemod: @$plotinfo[$plotIndex]->{Name}%s%s\" %s 0,-1\n",
		$instName ne '' ? "[$instName]" : '',
		@$plotinfo[$plotIndex]->{PType}=~/s/ ?
		" >>>Stacked<<<" : '',
                $mycfg->{GnuVersion}>=4.2 ? 'offset ' : '';

  #     P l o t    I t s e l f

  # NOTE that by setting the limits this way it's not necessary to do with
  # "plot [][]..." syntax
  if ($mask & 1)
  {
    # we can only have 2 labels which are numbered 0 and 1 respectively.
    printf INI "set yrange  [%s:%s]\n",
		@$plotinfo[$plotIndex]->{YMinLabel}->[0],
		@$plotinfo[$plotIndex]->{YMaxLabel}->[0];
    printf INI "set y2range [%s:%s]\n",
		@$plotinfo[$plotIndex]->{YMinLabel}->[1],
		@$plotinfo[$plotIndex]->{YMaxLabel}->[1]
			if defined(@$plotinfo[$plotIndex]->{YMinLabel}->[1]);

    # adds a tad of extra space at top so we can see line when maxed out
    print INI "set offsets 0,0,1,0\n";
  }
  else
  {
    print INI "set autoscale y\n";
    print INI "set autoscale y2\n";
  }

  #    G a t h e r    D a t a    F o r    1    P l o t    C o m m a n d

  # We have the names of ALL the files we want to plot in $allplots, though in many
  # cases it will only contain 1.

  # Remember, '$num' is the number of the file in the 'selected' hash
  my $firstFile=1;
  my $numFiles=scalar(@$allplots);
  for (my $num=0; $num<$numFiles; $num++)
  {
    # The following makes internal referencing easier.  Note that when plotting multiple files
    # at a time it's possible one or more may not contain the data required for this individual
    # plot (though it may contain data for others) and so we have a hole in our structure because
    # we're missing file level plotting parameters and when that happens be sure to skip plotting
    # that file for this specific plot name (note that we could have validated against ANY plot param).
    my $plotinfo=$allplots->[$num]->{plotinfo};
    my $fullname=$allplots->[$num]->{fullname};
    next    if !defined($plotinfo->[$plotIndex]->{PlotName});

    # In the case of instance data, which can have different column positions when we
    # have unique files and non-identical detail headers
    my $colIndex=$plotIndex;
    if ($instName ne '')
    {
      my $hasData=0;
      for (my $i=0; $i<scalar(@$plotinfo); $i++)
      {
        my $inst=$plotinfo->[$i]->{InstName};
        next    if !defined($inst);

        if ($plotinfo->[$i]->{InstName} eq $instName)
        {
	  $hasData=1;
	  $colIndex=$i;
          print "ColIndex reset to: $colIndex for inst '$instName' in $fullname\n"    if $debug & 64;
	  last;
        }
      }
      next    if !$hasData;
    }

    # build an array of variable specifications such that each is divided by
    # the associated divisor AND if a stacked plot that columns are added
    # together.
    my @colSpec;
    my $plotCols='';
    my $numLines=scalar(@{$plotinfo->[$plotIndex]->{YNames}});

    # when we can have holes in our plotting array and we're combining fields through math
    # expressions, as is possible with a mask of 2, we can't easily tell when we've changed
    # fields when processing data masked with an 8, so let's figure that out before we start.
    my @lastColumn;
    my $uniqueFlag=0;    # assume all 'yyy' components the same

    my $lastCol=0;
    my $specIndex=0;
    my $lastColFlag=1;
    my $specStart;
    for (my $i=0; ($mask & 10) && $i<$numLines; $i++)
    {
      my $plotCol= $${plotinfo[$colIndex]->{YColnum}}->[$i];
      my $plotOper=$${plotinfo[$plotIndex]->{Oper}}->[$i];

      # this tracks the last field seen with data in it
      $lastCol=$i    if $plotCol!=-1;

      # this means the last field ended an expression so THIS field is a new expression.
      if ($lastColFlag)
      {
        $lastColFlag=0;
        $specStart=$i;
      }

      # Whenever we hit the end of an expression, flag it and save the spec index associated
      # with this expression noting sometimes these fields may be all empty and therefore the
      # column number will be -1.  Also note when we hit an end of an expression don't update
      # our array if an entry already exists for the last 'real' column.
      if ($plotOper eq ' ')
      {
        $lastColFlag=1;
        $lastColumn[$lastCol]=$specIndex    if !defined($lastColumn[$lastCol]);
        #print "LASTCOL: $i  SPECSTART: $specStart INDEX: $specIndex  REAL: $lastCol\n";
	$specIndex++;
      }
    }

    my ($numSpecs, $cIndex)=(0,0);
    my $plotString='';
    my @lineNames;
    my $lastLabel;
    my $nextLabel;
    my @clabels=split(/,/, $plotinfo->[$plotIndex]->{CLabelStr});
    for (my $i=0; $i<$numLines; $i++)
    {
      # help make things a little clearer
      my $divisor =$${plotinfo[$plotIndex]->{YDiv}}->[$i];
      my $stacked= (@$plotinfo[$plotIndex]->{PType}=~/s/) ? 1 : 0;
      my $lineName=$${plotinfo[$plotIndex]->{YLabels}}->[$i];
      my $plotCol= $${plotinfo[$colIndex]->{YColnum}}->[$i];   # note use of $colIndex
      my $plotOper=$${plotinfo[$plotIndex]->{Oper}}->[$i];

      # We only do this when processing the first column specification for a line, which
      # is usually a single column in which case the names comes directly from the yname
      # field of the plot definition.  But if a compound one, peel off the next clabel.
      $lineNames[$numSpecs]=($plotOper eq ' ') ? $lineName : $clabels[$cIndex++]
          if $plotString eq '';

      # When doing funky column stuff, as in Environments in which you can have different column
      # names, like temp/speed BUT you don't have the same instance names for all, skip any
      # columns which aren't defined
      next  if $plotCol==-1 && $mask & 2;

      # Is this element a column number or a constant?
      # gnuplot thinks column 0 is really the 3rd element after date/time
      if ($plotCol>=0)
      {
        $plotCol+=3;
	$plotString.='$';     # col nums prefaces with '$'
      }
      else
      {
        $plotCol=$${plotinfo[$plotIndex]->{YNames}}->[$i];   # colname is actually constant
	if ($plotCol=~/(\d+)([KMG])/)
        {
	  $plotCol=$1;
	  $plotCol*=1024              if $2 eq 'K';
	  $plotCol*=1024*1024         if $2 eq 'M';
	  $plotCol*=1024*1024*1024    if $2 eq 'G';
        }
      }

      # Build up column expression noting usually a single digit prefaced by
      # a '$', but when dealing with compound expressions we need to build up
      # a set separated by the operators.  In ALL cases the last operator is
      # always a space [except when using a mask of 8]
      $plotString.="$plotCol";
      $plotString.="/$divisor"    if $divisor!=1;
      $plotString.="$plotOper";
      next    if $plotOper ne ' ' && !($mask & 8);

      # Mask 8 is special and currently only used for ExDS.  The big trick here is identifying the last
      # field in an expression and removing it from the end
      if ($mask & 8)
      {
        next    if !defined($lastColumn[$i]);

        # remove last character and reset plot name based on the 'clabels' string
        my $metaOper=quotemeta($plotOper);
        $plotString=~s/$metaOper$//;    # in case a trailing operator, which CAN happen
        $lineNames[$numSpecs]=$clabels[$lastColumn[$i]];
        #print "I: $i COL: $plotCol  INDEX: $lastColumn[$i]  LABEL: $clabels[$lastColumn[$i]]\n";
      }

      # We've now got the expression for the next plotting expression
      $plotString=~s/ $//;
      $plotCol=$plotString;
      $plotString='';

      if ($stacked)
      {
        # build a string that adds columns together, leaving off the
        # '+ on the first column.
        $plotCol="+$plotCol"    if $plotCols ne '';
        $plotCols.=$plotCol;
      }

      $colSpec[$numSpecs]=(!$stacked) ? "($plotCol)" : "($plotCols)";
      $numSpecs++;
    }

    #    B u i l d    A c t u a l    P l o t    C o m m a n d

    # Note that there are a couple of things we only do once for a given 'plot'
    # command even if mulitple files are processed when building it.  Also note
    # we may actually skip the first file in the list and so need a flag
    if ($firstFile)
    {
      # Is there enough room in the plot height for all the labels top fit in 1 column?
      # Note the the constants below were derived through trial and error
      # also note that $numSpecs is actually the number of lines in the plot
      if ($pparams->{legend}=~/on/i && $pparams->{adjust}=~/on/)
      {
        my $labelHeight=($mycfg->{fontSize} eq 'medium') ? 0.028 : 0.025;
        my $headerHeight=($mycfg->{fontSize} eq 'medium') ? 0.13 : 0.11;
        $height=$numSpecs*$labelHeight+$headerHeight    if ($height-$headerHeight)/$labelHeight<$numSpecs;
      }

      #    S e t    C a n v a s    S i z e

      if ($mycfg->{GnuVersion}>=4.2 && $pparams->{filetype}=~/png|tty/)
      {
        printf  INI "set size 1,1\n";    # make sure png file size = canvas size
      }
      else  # terminal/pdf output AND all older vesions
      {
        printf INI "set size $width,$height\n";
      }

      #    O u t p u t    T y p e    S p e c i f i c

      # Web-based output is always a 'png' file
      if (($htmlFlag && !defined($email)) || $pparams->{filetype}=~/png|tty/)
      {
        # From gnuplot 4.2 and forward we set canvas size here
        printf INI "set terminal png $color %s\n", ($mycfg->{GnuVersion}>=4.2) ? " size $width*700,$height*500" : '';
      }

      # for pdf or terminal output we need to place plot on page
      if ($pdfFlag || $pparams->{filetype}=~/term/)
      {
        # Since PDF and terminal based plots have multiple plots per page, we need
        # to figure out where to lay down each one (by moving the origin)
        # otherwise they'll land on each other
        my $temp=1-$context->{plotnum}*$height;
        $temp-=.02    if $filetype=~/term/;  # push down a skosh...
        printf INI "\nset origin 0,%f\n", $temp;
      }
      else
      {
        print INI "set output '$pngFile'\n"    unless $pparams->{filetype}=~/tty/;
      }

      # EXPERIMENTAL API - one time intialization
      if ($pparams->{subject}=~/API:(.*)\.ph/ && defined(&$apiCommands))
      {
        no strict 'refs';
        my $commands=&$apiCommands($mycfg, $pparams, $context, $filename);
        print INI $commands;
      }
      print INI "plot \\\n";
    }

    # magic!  If plotting a zipped file, change the file name to a command unzip it
    # BUT some files fail to unzip so remember that...
    $fullname="< gunzip -cd $fullname"    if $fullname=~/gz$/;

    # In most cases, $numSpecs==$numLines, because we have 1 column specifier
    # for each line.  However, when we have compound expressions those 2
    # numbers will differ.
    my ($lastYMin, $lastYMax);
    my $yAxisNum=1;
    $lastYMin=$lastYMax='';

    # stacked and filled (even though filled not currently enabled) are special
    my $stacked= (@$plotinfo[$plotIndex]->{PType}=~/s/) ? 1 : 0;
    my $filled= (@$plotinfo[$plotIndex]->{PType}=~/f/) ? 1 : 0;

    for (my $i=0; $i<$numSpecs; $i++)
    {
      # We're going to report stacked and filled plot data in reverse order
      my $j= ($stacked || $filled) ? $numSpecs-1-$i : $i;

      my $yMin=$${plotinfo[$plotIndex]->{YMin}}->[$j];
      my $yMax=$${plotinfo[$plotIndex]->{YMax}}->[$j];
      $yAxisNum++    if $lastYMin ne '' && ($lastYMin ne $yMin || $lastYMax ne $yMax);
      print "File: $fullname Using: 1:$colSpec[$j]\n"    if $debug & 8;

      # only first line gets a title.
      #  If an instance plot we need to stop at the last file that has data.
      $lastIndex=$lastInst    if $instName ne '';
      print  INI "'$fullname' using 1:$colSpec[$j] ";
      print  INI "axes x1y$yAxisNum "    if $numAxes>1;
      printf INI "title '%s' ",          $firstFile ? $lineNames[$j] : '';
      printf INI "with %s ls %d", @$plotinfo[$plotIndex]->{PType}=~/l/ ? "lines" : "points", $j+1;
      print  INI ", \\"    unless $num==$lastIndex && $i==($numSpecs-1);    # no \ for last line
      print  INI "\n";

      $lastYMin=$yMin;
      $lastYMax=$yMax;
    }
    $firstFile=0;
  }
  $context->{state}=2;

  # For web-based OR png plots, we do the rendering here, but if there
  # IS a pdf we want to call gnuplot only after the single ctl file is built
  # and that will be done in the final call to us (state=3)
  if (($htmlFlag && !defined($email)) || $filetype=~/png|tty/)
  {
    # Remember, to delete control file when we're done with it
    # If on a pc we have to quote the path to gnuplot just in case someone
    # installed it in a directory with embedded spaces in its name.
    close INI;
    my $command="$quote$mycfg->{GnuPlot}$quote $gnuCtlFile";
    displayText($mycfg, "Command: $command")    if $debug & 1;
    system($command);

    if (!$pparams->{incctl} && !($debug & 4))
    {
      displayText($mycfg, "unlink $gnuCtlFile")    if $debug & 1;
      unlink $gnuCtlFile;
    }

    # we need to make png file readable as well as deleteable
    `chmod a+wr $pngFile`    if !$pcFlag && $filetype!~/tty/;
  }
  return($pngFile);
}

# NOTE - even though this looks long, it's reasonably efficient.
# Also note that 'fdate' and 'tdate' get reset to reflect minimum/maximum date
# range of the match.  If this is NOT the behavior you're looking for
# you may need to save/reset those values between calls as is done in 'genPage()'.
sub findFiles
{
  my $findType=shift;
  my $mycfg=   shift;
  my $pparams= shift;
  my $globspec=shift;
  my $selected=shift;

  my $debug=   $mycfg->{debug};

  my $contains= $pparams->{contains};
  my $anyall=   $pparams->{anyall};
  my $fromDate= $pparams->{fdate};
  my $thruDate= $pparams->{tdate};
  my $unique=   $pparams->{unique};
  my $oneperday=$pparams->{oneperday};

  # If pdsh format in 'contains', load into a hard for exact matching
  my %hostnames;
  my $pdshFlag=0;
  if ($contains=~/\[/)
  {
    $pdshFlag=1;
    my @addresses=pdshFormat($contains);
    foreach my $address (@addresses)
    { $hostnames{$address}=''; }
  }

  # augment the glob to include finding gz files if it doesn't end in '*'
  $globspec.=" $globspec.gz"    if $globspec!~/\*$/;
  displayText($mycfg, "FindFiles -- Type: $findType Glob: >$globspec< From: $fromDate Thru: $thruDate Contains [$anyall]: $contains")    if $debug & 48;
  #TEST displayText($mycfg, "FindFile: $findType");

  my ($startDate, $fileDate, $selUnique, $size, $modtime, $index, $tzone, $tzlast, $tzsame);
  my ($minDate, $maxDate, $maxMTime, $dayspan)=(29999999, 0, 0, 0);
  my ($lastDate, $lastPrefix, $match)=('','',0);

  my $matchAll=($globspec=~/\*$/) ? 1 : 0;
  my @glob=glob($globspec);
  foreach my $fullname (@glob)
  {
    my $filename=basename($fullname);

    # Some basic filename format checks, noting if you want to put -something after the date, it's now ok
    # NOTE we display debugging output for 32 OR 2048
    displayText($mycfg, "Examining: $filename")    if $debug & 2080 && $findType!=3;
    next    if $filename=~/raw$|raw\.gz$/;

    # need to deal with filenames with/without time string separately in
    # case nodename look like a date and make sure all within date range
    # note the 2nd and 4th test.  This makes it optional to append a string
    # of a hyphen followed by anything after the date/time before the extension
    $fileDate='';
    $fileDate=$1    if $filename=~/-(\d{8})\./;
    $fileDate=$1    if $filename=~/-(\d{8})-.+\./;
    $fileDate=$1    if $filename=~/-(\d{8})-\d{6}\./;
    $fileDate=$1    if $filename=~/-(\d{8})-\d{6}-.+\./;
    next    if $fileDate eq '';
    next    if $fileDate<$fromDate || $fileDate>$thruDate;
    # If our globspec ended with '*', we also check for ALL valid extensions
    if ($matchAll)
    {
      # strip gz if present and note that the greedy pattern match assures we pick up the final '.'.
      my $testname=$filename;
      $testname=~s/\.gz//;
      $testname=~/\.*\.(\S+)$/;
      next    if index($mycfg->{validext}, $1)==-1;
    }

    # this logic also used in getLastPeriod() so make sure changes synchronized
    # note to self: where is getLastPeriod?
    my $submatch=1;
    if ($pdshFlag)
    {
      # since we got this far we know file is in one of the 2 formats
      my $host='';
      $host=$1    if $filename=~/(.*)-\d{8}\.tab/;
      $host=$1    if $filename=~/(.*)-\d{8}-\d{6}\.tab/;
      displayText($mycfg, "$host didn't match pdsh host spec")    if $debug & 2048 && !defined($hostnames{$host});
      next    if !defined($hostnames{$host});
    }
    elsif ($contains ne '')
    {
      # if doing an OR, make it look like a single string, with each chunk
      # OR'd together.  Otherwise we'll process each piece separately making
      # sure each one is there
      $contains=~s/\s+$//;    # just in case...
      $contains=~s/[ ,]/|/g    if $anyall=~/any/i;

      foreach my $pattern (split(/[\s+,]/, $contains))
      {
        $submatch=0    if ($filename!~/$pattern/)
      }

      # if none of the pieces matched, we DON'T have a match.
      next    if !$submatch;
    }

    # At this point, the file's date is in the correct range and if a 'contains' string
    # was specified it matches that too.  Now things get tricky...
    # If '-unique' not specified in CLI (typically only used during development), $unique
    # will be -1 on the first pass through here so set it to 1 or 0 based on whether or
    # not the first file that we see is unique or only date-stamped.
    $unique=($filename=~/-\d{6}\./) ? 1 : 0    if $unique==-1;

    # Note that when we're doing a scan of the directory for from/thru dates
    # ($findType==3) we look at all files, both unique and otherwise.
    # Also note at this point it's ok to find mixed unique and non-unique names,
    # as long as they're not for the same prefix (which we test later).
    next    if $filename=~/-\d{6}\./ && !$unique && $findType!=3;

    $match++;

    # These operations are cheap enough that we just do them all the time.
    $minDate=$fileDate    if $fileDate<$minDate;
    $maxDate=$fileDate    if $fileDate>$maxDate;

    # We want to find the newest selected file (by mtime) and use its date as the
    # new tdate (see return settings).  Note that these times are in gmt.
    ($size, $modtime)=(stat($fullname))[7,9];

    # we may be able to get rid of this once philippe makes up his mind  ;)
    # but for now, let's find out of all the selected files are in the same time zone.
    if ($findType==3 && defined($pparams->{timeframe}) && $pparams->{timeframe} eq 'float' && $size>0)
    {
      # I'm bummed I have to open the file hear and then later, but in don't see any alternative.
      # but at least it's only done for 'float'
      my $line;
      my $gzflag=($fullname=~/gz$/) ? 1 : 0;
      open FILE, "<$fullname" or liberror($mycfg, "Couldn't open '$fullname'")    if !$gzflag;
      my $ZFILE=Compress::Zlib::gzopen($fullname, 'rb')                           if $gzflag;

      while ((!$gzflag && ($line=<FILE>)) || ($gzflag && ($ZFILE->gzreadline($line))))
      {
        if ($line=~/# Date.* (\S+$)/)
        {
	  # adjust last mod time to zulu
	  my $tzone=$1;

	  # the very first time through we not only need to set tzlast, we also assume
	  # plots in same timezone.
	  if (!defined($tzlast))
	  {
	    $tzlast=$tzone;
	    $tzsame=$tzone;
	  }
	  $tzsame=0         if $tzone ne $tzlast;
	  $tzlast=$tzone;
	}
      }
    }

    # so we now know the maximum ending access time for all the selected
    # files AND if in float mode, those times are actually in UCT.
    $maxMTime=$modtime    if $size>0 && $modtime>$maxMTime;
    next    if $findType==3;

    # we have to figure out how may files to group together for a single plot.
    $filename=~/(.*)-(\d{8})(.*?)\.(.*)/;    # non-greedy so we pick up ext and ext.gz in $4
    my $prefix=$1;
    my $date=$2;
    my $unique=$3;
    my $ext=$4;
    $ext=~s/\.gz$//;    # remove .gz in case compressed

    # When the date OR prefix changes (including first pass), set a context flag for the next 2 tests
    # Note on very first pass we have a new prefix & date and so will set index to -1.
    my $newContext=0;
    if ($prefix ne $lastPrefix || ($oneperday && $date ne $lastDate))
    {
      my $newContext=1;
      $index=-1;
      $dayspan=0;
    }

    $match++;
    $index++;
    $dayspan++    if $date ne $lastDate;    # could be unique files on same date
    $lastPrefix=$prefix;
    $lastDate=$date;
    displayText($mycfg, "Selected:  $filename  Index: $index")    if $debug & 2080;

    # Just to keep our sanity, we're not allowing one to plot unique and non-unique files for the
    # same systems for the same period, using the first plot selected in group as a baselevel
    # Therefore set a flag for the very first we see a new prefix for a given date context
    if ($index==0)
    {
      $startDate=$date;
      $selUnique=($unique ne '') ? 1 : 0;
    }

    liberror($mycfg, "You've selected both unique and non-unique '$prefix' file for same period")
          if ($findType!=3 && $index>0 && (($selUnique && $unique eq '') || (!$selUnique && $unique ne '')));

    # This is tricky...  If we're not doing unique plots/day, which is typical, we need to use
    # the same date for all entries for the same system, so let's use the first file's start date.
    $date=$startDate    if !$oneperday;

    # But first grab header and check collectl version
    my $colver;
    my $nfsver='';
    my ($cltFlag, $mdsFlag, $ossFlag)=(0,0,0);

    # open file one way or the other
    my $gzflag=($fullname=~/gz$/) ? 1 : 0;
    open FILE, "<$fullname" or liberror($mycfg, "Couldn't open '$fullname'")    if !$gzflag;
    my $ZFILE=Compress::Zlib::gzopen($fullname, 'rb')                           if $gzflag;

    my $line;
    while ((!$gzflag && ($line=<FILE>)) || ($gzflag && ($ZFILE->gzreadline($line))))
    {
      if ($line=~/# Collectl:\s+V(\S+)/)
      {
	# Damn.  There are actually 2 different lines with 'collectl' on them and
        # we want the one that DOESN'T contain the string 'Subsys'.
	next    if $line=~/Subsys/;

        $colver=$1;
        if ($colver lt '2.1.1')
        {
          # Sorry, can't process this file
          displayText($mycfg, "file '$filename' was generated by collectl V$colver and cannot be plotted");
          displayText($mycfg, "you must regenerate the file with a newer version to proceed\n");
	  $match--;
	  last;
        }
	$selected->{$ext}->{$prefix}->{$date}->[$index]->{colver}=$colver;
	next;
      }
      if ($line=~/# Date.* (\S+$)/)
      {
	$tzone=$1;
	next;
      }

      if ($line=~/SubOpts:(.*)Options/)
      {
	my $subopts=$1;
        $nfsver= ($subopts=~/2/) ? 'NFS2' : 'NFS3';
        $nfsver.=($subopts=~/C/) ?    'C' : 'S';
        next;
      }

      if ($line=~/Lustre/)
      {
	$cltFlag++    if $line=~/CltInfo/;
        $mdsFlag++    if $line=~/NumMds: (\d+)/ && $1;
        $ossFlag++    if $line=~/NumOst: (\d+)/ && $1;
        next;
      }

      if ($line=~/^#Date/)
      {
        chomp $line;

        # A few header weren't quite what I wanted in this release to optimize
        # plotting AND this was a very limited release, so let's clean them
        # up and get them to look like the latest release wants them!
        if ($colver eq '2.1.1')
        {
          $line=~s/(\d+)/:$1/g               if $ext=~/ib|eln/;
          $line=~s/IB\]In/IB]InPkt/          if $ext=~/tab/;
          $line=~s/IB\]Out/IB]OutPkt/        if $ext=~/tab/;
          $line=~s/ELAN\]In/ELAN]InPkt/      if $ext=~/tab/;
          $line=~s/ELAN\]Out/ELAN]OutPkt/    if $ext=~/tab/;

          $line=~s/NFS\]V\d/$nfsver]/g       if $ext=~/tab/;
          $line=~s/NFSD/${nfsver}D/g         if $ext=~/nfs/;
          if ($ext=~/eln/)
          {
	    $line=~s/KBGet/GetKB/g;
	    $line=~s/KBPut/PutKB/g;
	    $line=~s/Ops//g;
          }
        }

        # NFS data in TAB file changed with collectl 3.2.1 and so did colplotlib.defs so we need
        # to make older files match.  eg [NFS2C]Reads -> [NFS]ReadsC and change details too
        $line=~s/NFS[23]([CS])\]Reads/NFS]Read$1/;
        $line=~s/NFS[23]([CS])\]Writes/NFS]Writes$1/;
        $line=~s/NFS([23])CD/NFS:$1cd/g;  # [NFS2CD] -> [NFS:2cd]
        $line=~s/NFS([23])SD/NFS:$1sd/g;  # [NFS2SD] -> [NFS:2sd]

        $selected->{$ext}->{$prefix}->{$date}->[$index]->{tzone}=$tzone;
        $selected->{$ext}->{$prefix}->{$date}->[$index]->{modtime}=$modtime;

        $selected->{$ext}->{$prefix}->{$date}->[$index]->{header}=$line;
        $selected->{$ext}->{$prefix}->{$date}->[$index]->{fullname}=$fullname;
	$selected->{$ext}->{$prefix}->{$date}->[$index]->{dayspan}=$dayspan;
        $selected->{$ext}->{$prefix}->{$date}->[$index]->{lusclt}=$cltFlag;
        $selected->{$ext}->{$prefix}->{$date}->[$index]->{lusmds}=$mdsFlag;
        $selected->{$ext}->{$prefix}->{$date}->[$index]->{lusoss}=$ossFlag;

        close FILE;
        last;
      }
    }

    # NOTE - the resulting display may have unplotted icons in it.  We could simply build up a list of messages
    # in a string and display in routine calling findFiles()s (tested and works), but doesn't seem to be worth
    # the pain since so ugly.
    if (!defined($colver))
    {
      displayText($mycfg, "File '$fullname' does not have valid collectl header and must not be selected");
      $match--;
      next;
    }

    # Optimization - if we're doing the find on behalf of a single png file for a web page,
    # we only return the files for the same date and stop the search.
    last    if ($match && $findType==2 && $newContext);
  }

  # Convert the max access time (which IS in utc for 'float') to date/time, noting this will
  # use the local times which is WRONG for float when type != 3 but since only looked at
  # in colplot for type 3 we're ok.
  my ($secs, $mins, $hour, $day, $mon, $year)=localtime($maxMTime);
  my $adate=sprintf("%d%02d%02d", $year+1900, $mon+1, $day);
  displayText($mycfg, sprintf("TZone: $tzone  MaxTime: %02d:%02d\n", $hour, $mins))    if $debug & 32;

  # Always reset the from/thru dates to reflect what we found and toss in the maximum
  # hours/mins and whether or not we have different time zones represented
  # even though live mode is currently the only time we need it.
  my $timeframe=(defined($pparams->{timeframe})) ? $pparams->{timeframe} : '';
  $pparams->{maxhour}=$hour;
  $pparams->{maxmins}=$mins;
  $pparams->{fdate}=$minDate;
  $pparams->{tdate}=($timeframe=~/float/) ? $adate : $maxDate;
  $pparams->{tzone}=$tzone;

  # be sure to ONLY save during this phase of latter calls will change it
  # which we don't want
  $pparams->{tzsame}=$tzsame    if $findType==3;

  return($match);
}

#########################################################
#    D e v e l o p m e n t    ' h e l p e r s '
#########################################################

# While showParams() has been exposed as part of the cli for colplot and
# colgui, its primary purpose is still for developers and/or people who
# are writing their own plot definitions.  showSelected is clearly not for
# anyone but me since calls to it are commented out!

sub showParams
{
  my $mycfg=   shift;
  my $plotref= shift;
  my $system=  shift;

  my $debug=   $mycfg->{debug};

  $system='???'    if !defined($system);
  displayText($mycfg, "*** PLOT PARAMS for $system ***");

  for (my $i=0; $i<scalar(@$plotref); $i++)
  {
    # As with elsewhere, there can be holes in the plot definitions
    next    if !defined(@$plotref[$i]);

    my $temp=sprintf("Plot[$i]: %s FirstName: %s%s PType: %s Mask: %s  CLabels: %s YLabels: %s",
                      @$plotref[$i]->{PlotName}, @$plotref[$i]->{Name},
                      @$plotref[$i]->{InstName} ne '' ? ":@$plotref[$i]->{InstName}" : '',
                      @$plotref[$i]->{PType},    @$plotref[$i]->{Mask}, @$plotref[$i]->{CLabelStr},
                      scalar(@{@$plotref[$i]->{YMaxLabel}}));
    for (my $j=0; $j<scalar(@{@$plotref[$i]->{YMaxLabel}}); $j++)
    {
      $temp.=sprintf("[%d-%d]", @$plotref[$i]->{YMinLabel}->[$j],
                                @$plotref[$i]->{YMaxLabel}->[$j]);
    }
    displayText($mycfg, $temp);

    for (my $j=0; $j<scalar(@{@$plotref[$i]->{YNames}}); $j++)
    {
      my $col=@$plotref[$i]->{YColnum}->[$j];
      next    if $col==-1 && $debug & 1024;

      $temp=sprintf("  Name[%3d]: %-20s  Label: %-7s  Col: %3s  YMin/Max: %-8s Div: %4s %s",
               $j, @$plotref[$i]->{YNames}->[$j],
               $col>=0 ? @$plotref[$i]->{YLabels}->[$j] : '',
	       $col>=0 ? $col : '',   # actually -1 is a constant or ENV type data
	       $col>=0 ? sprintf("%d->%d", @$plotref[$i]->{YMin}->[$j], @$plotref[$i]->{YMax}->[$j]) : '',
               $col>=0 ? @$plotref[$i]->{YDiv}->[$j] : '', @$plotref[$i]->{Oper}->[$j]);
      displayText($mycfg, $temp);
    }
  }
  #displayText($mycfg, '');
  exit    if $debug & 256;
}

sub showSelected
{
  my $mycfg=   shift;
  my $tag=     shift;
  my $selected=shift;
  my $type=    shift;

  displayText($mycfg, "ShowSelected called at '$tag'");
  foreach my $ext (sort keys %$selected)
  {
    foreach my $prefix (sort keys %{$selected->{$ext}})
    {
      foreach my $date (sort keys %{$selected->{$ext}->{$prefix}})
      {
        my $maxIndex=scalar(@{$selected->{$ext}->{$prefix}->{$date}});
        displayText($mycfg, "  selected->{$ext}->{$prefix}->{$date}");
        foreach (my $index=0; $index<$maxIndex; $index++)
        {
	  next    if !defined($selected->{$ext}->{$prefix}->{$date}->[$index]);
          displayText($mycfg, "    ->[$index]: $selected->{$ext}->{$prefix}->{$date}->[$index]->{fullname}".
	                      " ->[$index]->{dayspan}: $selected->{$ext}->{$prefix}->{$date}->[$index]->{dayspan}");
          if ($type==2)
          {
            my $numplots=scalar(@{$selected->{$ext}->{$prefix}->{$date}->[$index]->{plotinfo}});
            for (my $plotnum=0; $plotnum<$numplots; $plotnum++)
            {
	      # Skip holes in array
	      next    if !defined($selected->{$ext}->{$prefix}->{$date}->[$index]->{plotinfo}->[$plotnum]);

	      my $temp="         selected->{$ext}->{$prefix}->{$date}->[$index]->{plotinfo}->[$plotnum]";
	      my $numnames=scalar(@{$selected->{$ext}->{$prefix}->{$date}->[$index]->{plotinfo}->[$plotnum]->{YNames}});
              for (my $namenum=0; $namenum<$numnames; $namenum++)
              {
	        $temp.=" Y$namenum: $selected->{$ext}->{$prefix}->{$date}->[$index]->{plotinfo}->[$plotnum]->{YNames}->[$namenum]";
              }
	      displayText($mycfg, $temp);
            }
          }
        }
      }
    }
  }
}

sub dumpPlotref
{
  my $plotref=shift;
  my $title=  shift;

  print "*** $title ***\n";
  for (my $i=0; $i<scalar(@$plotref); $i++)
  {
    my $ref=$plotref->[$i];
    print "YName: $ref->{YNameStr}\n";
    print "Label: $ref->{YLabelStr}\n";
    print "YMin:  $ref->{YMinStr}\n";
    print "YMax:  $ref->{YMaxStr}\n";
    print "YDiv:  $ref->{YMinStr}\n";
  }
}

#####################################################
#    T e x t    O u t p u t
#####################################################

# This may be a little more involved than it has to be, but the idea
# is there is the occasional need to generate output messages, either
# as simple text and/or when debugging switches are set.  Sometime one
# is running in command mode and at others in html and these routines
# need to know which so that they can display well formatted output.
# Finally, in the case of a fatal error, one simply needs to report the
# message and exit (hence 'liberror').

# Things are organized as they are to make it possible to be used by the
# main programs using this library.

# As it says, report the message and exit.
sub liberror
{
  my $mycfg= shift;
  my $errorText=shift;

  displayText($mycfg, $errorText, 3);
  exit;
}

# Since library routines can be used from both a command line or a browser, let's be
# smarter (and prettier) about printing messages as well as debugging info
sub displayText
{
  my $mycfg=shift;
  my $text= shift;
  my $level=shift;

  my ($pre, $post)=('','');
  if ($mycfg->{htmlflag})
  {
    htmlHeader($mycfg);
    $pre= defined($level) ? "<h$level>" : "<br>";
    $post=defined($level) ? "</h$level>" : "";
  }
  printf "%s%s%s\n", $pre, $text, $post;
}

sub htmlHeader
{
  my $mycfg=shift;
  my $title=shift;

  return    if !$mycfg->{htmlflag};
  return    if  $mycfg->{htmlhdr};

  print "Content-type: text/html\n\n";
  print "<html>\n";
  print "<head>\n";
  print "<title>$title</title>\n"    if defined($title);
  print "</head>\n";
  $mycfg->{htmlhdr}=1
}

sub htmlFooter
{
  my $mycfg=shift;
  # only makes sense when a header printed
  return    if !$mycfg->{htmlflag};
  return    if !$mycfg->{htmlhdr};

  print "</body>\n";
  print "</html>\n";
}

# Convert date/time to seconds
sub seconds
{
  my $date=shift;
  my $time=shift;

  my $year=substr($date, 0, 4);
  my $mon= substr($date, 4, 2);
  my $day= substr($date, 6, 2);
  my $hour=substr($time, 0, 2);
  my $mins=substr($time, 3, 2);

  my $seconds=($hour<24) ?
	timelocal(0, $mins, $hour,   $day, $mon-1, $year-1900) :
	timelocal(0, $mins, $hour-1, $day, $mon-1, $year-1900)+3600;
  return($seconds);
}

####################################################
#    A d d r e s s    C o n v e r s i o n
####################################################

sub pdshFormat
{
  my $address=shift;

  # Break out individual address, putting 'pdsh' expressions back
  # together if they got split
  my $partial='';
  my $addressList='';
  foreach my $addr (split(/[ ,]/, $address))
  {
    # This is subtle.  The '.*' will match up to the rightmost '['.  If a ']'
    # follows, possibly followed by a string, we're done!  We use this same
    # technique later to determine when we're done.
    if ($addr=~/.*\[(.*)$/ && $1!~/\]/)
    {
      $partial.=",$addr";
      next;
    }

    if ($partial ne '')
    {
      $partial.=",$addr";
      next    if $partial=~/.*\[(.*)$/ && $1!~/\]/;
      $addr=$partial;
    }
    $addr=~s/^,//;
    $addressList.=($addr!~/\[/) ? "$addr " : expand($addr);
    $partial='';
  }
  $addressList=~s/ $//;
  return((split(/[ ,]/, $addressList)));
}

# Expand a 'pdsh-like' address expression
sub expand
{
  my $addr=shift;
  #print "EXPAND: $addr\n";

  $addr=~/(.*?)(\[.*\])(.*)/;
  my ($pre, $expr, $post)=($1, $2, $3);
  #print "PRE: $pre  EXPR: $expr  POST: $post\n";

  my @newStack;
  my @oldStack='';    # need to prime it
  foreach my $piece (split(/\[/, $expr))
  {
    next    if $piece eq '';    # first piece always blank

    # get rid of trailing ']' and pull off range
    $piece=~s/\]$//;
    my ($from, $thru)=split(/[-,]/, $piece);
    $from=~/^(0*)(.*)/;
    #print "PIECE: $piece FROM: $from THRU: $thru  1: $1  2: $2\n";

    my $pad=length($1);
    my $num=length($2);
    my $len=$pad+$num;
    my $spec=(!$pad) ? "%d" : "%0${len}d";

    $piece=~s/-/../g;
    $piece=~s/^0*(\d)/$1/;                # gets rid of leading 0s
    $piece=~s/([\[,.-])0*(\d)/$1$2/g;     # gets rid of other numbers with them

    my @numbers=eval("($piece)");

    undef @newStack;
    foreach my $old (@oldStack)
    {
      foreach my $number (@numbers)
      {
        my $newnum=sprintf("$spec", $number);
        push @newStack, "$old$newnum";
      }
    }
    @oldStack=@newStack;
  }

  my $results='';
  foreach my $spec (@newStack)
  { $results.="$pre$spec$post "; }

  return $results;
}

1;

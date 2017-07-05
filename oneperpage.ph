# defaults:

my $plottop=.95;
my $plotbot=.05;

my $dateFormat='%Y%m%d';
my $showTitles=0;

sub oneperpageValid
{
  my $pparams=shift;

  my $reason='';
  $reason="cannot use 'oneperpage' from the web interface"    if $pparams->{uitype}!=2;
  return($reason);
}

sub oneperpageInitParams
{
  my $mycfg=  shift;
  my $pparams=shift;
  my $context=shift;
  my $params= shift;

  liberror($mycfg, "the 'oneperpage' module does NOT work via the web")    if $pparams->{uitype}==1;

  print "WARNING!!!  Non-uniform number of plots/file will screw up page formatting\n"    if !$pparams->{numuniform};

  if (defined($params) && $params ne '')
  {
    foreach my $param (split(/,/,$params))
    {
      liberror($mycfg, "'oneperplot' does not support parameter: $param")    if $param!~/[Dt]/;
      my ($name, $value)=(split(/=/, $param));

      $dateFormat='%m/%d'     if $param=~/D/;
      $showTitles=1           if $param=~/t/;
    }
  }

  $pparams->{height}=($plottop-$plotbot)/$context->{plotsperpage};

  my $commands=<<HJEOF;

set nogrid
set lmargin 10
set rmargin 20
set tmargin 0
set bmargin 1
set key top right outside Right samplen 1 spacing 0.6

set style line 1 lt  3 lw 1.5 pt 0 ps 1.0
set style line 2 lt  1 lw 0.5 pt 0 ps 1.0
set style line 3 lt  7 lw 1 pt 0 ps 1.0
set style line 4 lt  9 lw 1 pt 0 ps 1.0
set style line 5 lt  2 lw 1 pt 0 ps 1.0
set style line 6 lt  5 lw 1 pt 0 ps 1.0
set style line 7 lt  4 lw 1 pt 0 ps 1.0
set style line 8 lt  6 lw 1 pt 0 ps 1.0

set border 15 linewidth 0.2

HJEOF
 
  return($commands);
}

sub oneperpageCommands
{
  my $mycfg=  shift;
  my $pparams=shift;
  my $context=shift;
  my $filename=shift;

  $ppp=$context->{plotsperpage}=$pparams->{numuniform};
  my $plotnum=$context->{plotnum};

  my $commands='';
  $commands.="set label 1 \"Datafile: $filename using colplot: oneperpage]\" at screen 0.01,0.98\n";
  $commands.="set title \"\"\n"    if !$showTitle;
  $commands.=sprintf("set origin 0,%f\n", $plottop-$plotnum*$pparams->{height});
  $commands.=sprintf("set format x %s\n", ($plotnum==$context->{plotsperpage}) ? "\"%H:%M:%S\\n$dateFormat\"" : '""');
 return($commands);
}

1;

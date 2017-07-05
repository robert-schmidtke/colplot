# debug
#  1 - allow running from cli

# defaults:
my $debug=0;
my $height=.1;
my $width=.04;
my $yrange='';    # leave as is
# - turn off x-axis (bmargin)
# - turn off y-axis (lmargin)
# - turn off legend (rmargin)
# - minimal room for title (tmargin)
my ($bmargin,$lmargin,$rmargin,$tmargin,$links)=(0,0,0,1,0);

my $subtitle='';

sub tinyValid
{
  my $pparams=shift;
  my $params= shift;

  $debug=$1    if defined($params) && $params=~/d=(\d+)/;

  my $reason='';
  $reason="cannot use 'tiny' from the cli interface"    if $pparams->{uitype}!=1 && !($debug & 1);

  return($reason);
}

sub tinyInitParams
{
  my $mycfg=  shift;
  my $pparams=shift;
  my $context=shift;
  my $params= shift;

  if (defined($params))
  {
    foreach my $param (split(/,/,$params))
    {
      my ($name, $value)=(split(/=/, $param));
      liberror($mycfg, "'tiny' does not support parameter: $param")    if $name!~/[bdhlrstwyL]/;

      $debug=$value      if $name=~/d/;
      $bmargin=$value    if $name=~/b/;
      $lmargin=$value    if $name=~/l/;
      $rmargin=$value    if $name=~/r/;
      $tmargin=$value    if $name=~/t/;
      $height=$value     if $name=~/h/;
      $width=$value      if $name=~/w/;
      $subtitle=$value   if $name=~/s/;
      $yrange=$value     if $name=~/y/;
      $links=$value      if $name=~/L/;
    }
  }

  # height width too messy so do up front so let colplot do the calculations
  # for both 'set size' and 'set png'
  $pparams->{height}=$height;
  $pparams->{width}= $width;
  $pparams->{links}=$links;

  $commands='';
  return($commands);
}

sub tinySubtitle
{
  return($subtitle);
}

sub tinyCommands
{
  my $mycfg=  shift;
  my $pparams=shift;
  my $context=shift;
  my $filename=shift;

  # just use rightmost 3-digit node numbers from the filename, noting some are only 3 digits!
  $filename=~/\d*(\d{3})-\d{8}/;
  #print "FILE: $filename\n";
  #$filename="FOO";
  my $nodeNum=$1;

  my $commands='';
  $commands.="set bmargin $bmargin\n";
  $commands.="set lmargin $lmargin\n";
  $commands.="set rmargin $rmargin\n";
  $commands.="set tmargin $tmargin\n";
  $commands.="set nokey\n"             if $rmargin==0;
  $commands.="set yrange $yrange\n"    if $yrange ne '';
  $commands.=sprintf("set title \"$nodeNum\" %s 0,-1\n", $mycfg->{GnuVersion}>=4.2 ? 'offset ' : '');
  return($commands);
}

sub tinyLinks
{
  my $mycfg=shift;
  my $href= shift;

  my $debug=$mycfg->{debug};

  $href=~s/<img src=//;
  $href=~s/genplot/genpage/;
  $href=~s/">$//;

  if ($debug & 128)
  {
    displayText($mycfg, ">>>Before<<<");
    foreach my $var (split(/&/, $href))
    { print "<br>VAR: $var\n"; }  
  }

  $href=~s/subject.*\&//;
  $href=~s/plots=.*?\&/plots=sumall&/;
  $href=~s/filename=(.*?)\&//;
  my $file=$1;
  my $dir=dirname($file);

  # remove date and everything to the right of it so we select ALL files
  # in case they span mulitple dates
  $file=basename($file);
  $file=~s/-\d{8}.*//;

  $href.="&contains=$file";
  $href.="&directory=$dir";
  $href.="&tabcol=sp";
  $href.="&timeframe=fixed";
  $href.='"';

  $href=~s/legend=off/legend=on/;
  $href=~s/thick=1/thick=3/;

  if ($debug & 128)
  {
    displayText($mycfg, ">>>After<<<");
    foreach my $var (split(/&/, $href))
    { print "<br>VAR: $var\n"; }  
  }

  return($href); 
}

1;

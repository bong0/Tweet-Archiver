#!/usr/bin/env perl
# ##
# ## FILE: twarchive.pl
# ##
# ## DESCRIPTION: Script for archiving old tweets and countinuously appearing ones (via cron, daemontools, etc.)
# ##              extensible to support similar api calls like the implemented ones 'user_timeline' and 'mentions'
# ##
# ## AUTHOR: bongo
# ## DATE: (06..09).04.2012 (basic backup procedure and cfg taken from a script written by balu @19.02.2011)
# ## VERSION: 0.522
# ##
# TODO: include option to exclude RTs
require Encode;
use Data::Dumper;
use Net::Twitter;
use Config::Simple;
use Scalar::Util 'blessed';
use File::Copy;
use File::Basename;
use strict;
sub generate_cfg;
my $cfg = new Config::Simple();
############# USER VARIABLE #############
my $cfgFile = $ENV{HOME}."/etc/twarchive.conf"; # location of config file
########################################
# Try to find config in script dir if not found in pref declared dir
if (! (-e $cfgFile)) {
    $cfgFile = dirname(__FILE__)."/twarchive.conf";
}
########################################
$cfg->read($cfgFile) or generate_cfg();
$cfg->autosave(1);

our $dbg=0;
our $verb=0;
if($ARGV[0] =~ "((-v)|(--verbose))"){
  $verb = 1;
  use Devel::Peek;
  use Data::Dumper;
}
elsif($ARGV[0] =~ "((-d)|(--debug))"){
    $dbg = 1;
	$verb= 1;
}

#check cfg items
my @cfg_items = qw(consumer_key consumer_secret data_dir
		   own_tweets.backup own_tweets.file own_tweets.last_tweet_id
		   mentions.backup mentions.file mentions.last_tweet_id
                   favorites.backup favorites.file favorites.last_tweet_id);

foreach(@cfg_items) {
  my $cfg_val = $cfg->param($_);
  chomp($cfg_val);
  if(!$cfg_val) { die("option $_ not specified!"); }
  if($_ =~ /((key)|(secret))$/){
	if( !($cfg_val =~ /[A-Za-z0-9]+/) ){
	  die("option $_ must contain only hexadecimal characters");
	}
	next;
  }
  if($_ =~ /tweet_id$/){
	if( !($cfg_val =~ /[0-9]/) ){
	  die("option $_ must contain only decimal characters");
	}
	next;
  }
  if($_ =~ /backup$/){
	if( !($cfg_val =~ /((yes)|(1)|(no)|(0))/) ){
	  die("option $_ must be one of the following. [yes,1,no,0]");
	}
	next;
  }
  if($_ =~ /^data_dir$/){
	if(!(-e $cfg_val)){
	  print "[-] did not find specified data directory $cfg_val, would you like me to create it? [Y/n] ";
	  if(lc(<STDIN>) =~ /^n$/){  print "[-] cannot continue without data directory, exiting..."; exit 1; }
	  else { mkdir($cfg_val); }
	}
	next;	
  }
}
my $backup_own_tweets = $cfg->param('own_tweets.backup');
my $backup_mentions = $cfg->param('mentions.backup');
my $backup_favorites = $cfg->param('favorites.backup');
my $dataPath = $cfg->param('data_dir');

# setup nt module
my $nt = Net::Twitter->new(
    traits          => ['API::RESTv1_1', 'OAuth'],
    consumer_key    => $cfg->param('consumer_key'),
    consumer_secret => $cfg->param('consumer_secret')
);

#check existence of access token and secret
my $access_token = $cfg->param('access_token');
my $access_token_secret = $cfg->param('access_token_secret');
if ($access_token && $access_token_secret) {
  $nt->access_token($access_token);
  $nt->access_token_secret($access_token_secret);
}
#authorize if check failed
unless ( $nt->authorized ) {
      # The client is not yet authorized: Do it now
      print "Authorize this app at ", $nt->get_authorization_url, " and enter the\nPIN > ";

      my $pin = <STDIN>; # wait for input
      chomp $pin;

      my($access_token, $access_token_secret, $user_id, $screen_name) = $nt->request_access_token(verifier => $pin);
      $cfg->param('access_token', $access_token);
      $cfg->param('access_token_secret', $access_token_secret);
}

sub generate_cfg {
  print "You have no config file under $cfgFile . Would you like to auto-create one? [Y/n] ";
  if(lc(<STDIN>) =~ "n"){ print "Please copy your config to $cfgFile or modify the \$cfgFile variable.$/"; exit 0;}
  open(CFG, ">$cfgFile") or die("Could not generate config file: $!");
  print CFG <<EOCFG;
[own_tweets]
last_tweet_id=
first_tweet_id=
file=backup_tweets
backup=yes

[mentions]
last_tweet_id=
file=backup_mentions
backup=yes

[favorites]
last_tweet_id=
file=backup_favorites
backup=yes

[default]
access_token_secret=
consumer_secret=
access_token=
consumer_key=
backup_old=yes
data_dir=$ENV{HOME}/tweet_archive/
EOCFG
  close(CFG);
}

sub prepend { #prepends some buffer to file
  my ($file, $buffer) = @_;
  if($dbg){ print "prepending buffer to ".$file."\nbuffer contains: ".$buffer."\n"; }
  open(TMPFILE, ">$file.tmp") or die("[--] Failed to create tempfile: $!");
  print TMPFILE $buffer; #write buffer to tmpfile

  if(!(-e $file)){ open(FILE,">$file"); close(FILE); } #create file is it doesn't existence
  open(ORIGFILE, "<$file") or die("[--] Failed to open file for reading: $!");
  while (<ORIGFILE>) { #append rest of original
    print TMPFILE $_;
  }
  close(ORIGFILE);
  close(TMPFILE);
  move("$file.tmp", "$file");
}

sub append { #analoguos to prepend
  my ($file, $buffer) = @_;
  if($dbg){ print "appending buffer to ".$file."\nbuffer contains: ".$buffer."\n"; }
  open (FILE ,">>$file") or die("[--] Failed to open file for appending: $!");
  print FILE $buffer;
}

sub backup_tweets {
  my $backup_file = $_[0]; # destination file
  my $lastid = $_[1]; # last tweet id
  my $api_method = $_[2]; # select API-method
  my $backup_old = $_[3]; # the "catch-up" option on firstrun

  my $page = 1; # request page
  my $oldest_tweet_id = -1; # oldest tweet id in API response (the last array item)
  my $newest_tweet_id = -1; # newest tweet id of last batch

  if($verb){
    print "backup file: ".$backup_file."\n";
    print "lastid: ".$lastid."\n";
  }

  my $err = undef; # possible err code we find afer eval
  if(!$backup_old){
    open(FILE, ">>$backup_file");
  }
  while( 1 ){
    if($err){
	  if($dbg) {print "Dumper:".Dumper($err);}
      if($err->code == 502) {
		if($verb) { print "[E] API returned a 502, retrying...\n"; }
		$page--;
      }
      elsif($err->code == 503) {
		if($verb) { print "[-] API is overloaded, sleeping 10s\n"; }
		sleep(10);
      }
      elsif($err->code == 500) {
		if($verb) { print "[--] API is broken, exiting...\n"; }
		exit 1;
      }
      else {
		die $@;
      }
    }

    eval {
      if($verb){ print "page: ".$page."\n"; }
	  my $statuses = undef; # holds api response
	  if($api_method =~ "mentions"){
	    if($verb){ print "loading mentions...\n"; }
		if(!$lastid){
		  $statuses = $nt->mentions({count => 200, page => $page});
		}
		else {
		  $statuses = $nt->mentions({count => 200, since_id => $lastid, page => $page});
		}
	  }
	  elsif($api_method =~ "user_timeline"){
		if($verb){ print "loading user timeline...\n"; }
		if(!$lastid){
		  $statuses = $nt->user_timeline({count => 3200, include_rts => 1});
	    	}
	    else {
		  $statuses = $nt->user_timeline({count => 3200, since_id => $lastid,
						  page => $page, include_rts => 1});
	    }	 	
	  }
	  elsif($api_method =~ "favorites"){
		if($verb){ print "loading favorites...\n"; }
                if(!$lastid){
                  $statuses = $nt->favorite({count => 200});
                }
		else {
                  $statuses = $nt->favorites({count => 200, since_id => $lastid,
                                              page => $page});
            	}
	  }
	  else{ die("No API method specified"); }
	  if($verb){ print "index_oldest:".(@$statuses-1)."\n"; }

	  if(@$statuses){
	    $oldest_tweet_id = (@$statuses[(@$statuses-1)])->{id_str};
		if((($page == 1)|!$page) && ($lastid < (@$statuses[0])->{id_str}) ){
		  $newest_tweet_id = (@$statuses[0])->{id_str};
		  if($verb){ print "setting newest tweet id to:".$newest_tweet_id.$/; }
		}
	  }
	  else {
		$err = $@; last;
	  }

	  my $write_buffer = undef;
	  for (my $i=(@$statuses-1);$i >= 0;$i--){
	    my $status = @$statuses[$i]; #pick current status from API response
		$write_buffer .= Encode::encode_utf8("$status->{created_at} $status->{time} <$status->{id_str}> <$status->{user}{screen_name}> $status->{text}\n");
	  }
	  if($backup_old){
		prepend("$backup_file", $write_buffer);
	  }
	  else {
		append("$backup_file", $write_buffer);
	  }
	}; # END EVAL
	$err = $@;
	$page++;
	if($verb){ print "oldest_tweet_id of batch:".$oldest_tweet_id."\n"; }
   }
   if ( $err ) { #catch all other errors
      die $@ unless blessed $err && $err->isa('Net::Twitter::Error');
      warn "HTTP Response Code: ", $err->code, "\n",
		   "HTTP Message......: ", $err->message, "\n",
		   "Twitter error.....: ", $err->error, "\n";
	}
  close(FILE);

  if($api_method=~"user_timeline"){
	if($newest_tweet_id > $cfg->param('own_tweets.last_tweet_id')){
	  if($verb){ print "writing own_tweets.last_tweet_id=$newest_tweet_id to conf$/"; }
	  $cfg->param('own_tweets.last_tweet_id', $newest_tweet_id); #write back lastid to conf
	}
  }
  elsif($api_method=~"mentions"){
	if($newest_tweet_id > $cfg->param('mentions.last_tweet_id')){
	  if($verb){ print "writing mentions.last_tweet_id=$newest_tweet_id to conf$/"; }
	  $cfg->param('mentions.last_tweet_id', $newest_tweet_id); #write back lastid to conf
	}
  }
  elsif($api_method=~"favorites"){
        if($newest_tweet_id > $cfg->param('favorites.last_tweet_id')){
          if($verb){ print "writing favorites.last_tweet_id=$newest_tweet_id to conf$/"; }
          $cfg->param('favorites.last_tweet_id', $newest_tweet_id); #write back lastid to conf
        }	
  }
  $cfg->save();
}

sub showRateLimit {
  my $ratelimit = $nt->rate_limit_status({ authenticate => 1 });
  
  if($verb){ print Dumper($ratelimit); print "hits remaining: " .$ratelimit->{remaining_hits}."/".$ratelimit->{hourly_limit}."\n"; }
  #has to be fixed
  #if($ratelimit->{remaining_hits} <= 5){
  #	die "Remaining: $ratelimit->{remaining_hits} RATE LIMIT ALMOST REACHED -- will not do further requests";
  #}
}

################ BEGIN MAIN ################
my $backup_old = 0;
if(! (-e $dataPath.$cfg->param('own_tweets.file'))){
  print "This seems to be the first run. Do you want to catch up your old tweets now? [y/N] ";
  if(lc(<STDIN>) =~ /^y$/){
	if(!($cfg->param('own_tweets.first_tweet_id')=~/^[0-9]+$/)) {
	  die("You need to specify the id of you first tweet to use the feature!");
	}
	$backup_old=1;
  }
}

showRateLimit();

if($backup_own_tweets =~ /^((yes)|(1))$/){
  my $tweetCursor = $cfg->param('own_tweets.last_tweet_id');
  if($backup_old){
	$tweetCursor = $cfg->param('own_tweets.first_tweet_id'); #const
  }
  else {
	if(!(-e $dataPath.$cfg->param('own_tweets.file'))){
	  $tweetCursor = undef; #ignore ID in the first run
	}
  }
  backup_tweets($dataPath.$cfg->param('own_tweets.file'),	#output goes here
				$tweetCursor,		#at which tweet id to start the backup (the earlier, the more tweets get caught)
				"user_timeline",	# backup the user's timeline (own tweets & RTs)
				$backup_old); 		# backup_old = true (we have to prepend data instead of appending)
}
if($backup_mentions =~ /^((yes)|(1))$/){
  my $mention_last_id = $cfg->param('mentions.last_tweet_id');
  if(!(-e $dataPath.$cfg->param('mentions.file'))){
	$mention_last_id = ""; #ignore ID in the first run
  }
  backup_tweets($dataPath.$cfg->param('mentions.file'),	# output goes here
				$mention_last_id, # the API doesn't provide us >200 latest items anyway
				"mentions",	# backup the user's mentions (by others)
				0); #regular mode
}		
if($backup_favorites =~ /^((yes)|(1))$/){
  my $fav_last_id = $cfg->param('favorites.last_tweet_id');
  if(!(-e $dataPath.$cfg->param('favorites.file'))){
        $fav_last_id = ""; #ignore ID in the first run
  }
  backup_tweets($dataPath.$cfg->param('favorites.file'), # output goes here
                                $fav_last_id, # the API doesn't provide us >200 latest items anyway
                                "favorites",  # backup the user's mentions (by others)
                                0); #regular mode
}

if($verb){print "run finished\n";}


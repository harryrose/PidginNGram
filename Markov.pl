use Purple;
use Data::Dumper;
use Storable;

my $saveDir = "/home/harry/.HMarkov";

my $plugname = "MarkovPlugin";
my $beginToken = "__BEGIN__";
my $endToken = "__END__";
my $nGramSize = 3;

my $nWordsStorage = "$saveDir/nwords$nGramSize";
my $allButLastStorage = "$saveDir/abl$nGramSize";
my $probabilityCacheStorage = "$saveDir/pc$nGramSize";
my $noNGramsStorage = "$saveDir/no$nGramSize";

#Maintains counts of how often groups of $nGramSize Words come up
my %NWords = {};

#Maintains counts of how often groups of $nGramSize-1 Words come up.
my %AllButLast = {};

my %ProbabilityCache = {};

my $NumberOfNgrams = 0;

my %SendingStatus = {};

my $SendColourHex = "#0000FF";

sub SaveMemory {
	DEBUG("Storing to memory");
	store \%NWords, $nWordsStorage;
	store \%AllButLast, $allButLastStorage;
	store \%ProbabilityCache, $probabilityCacheStorage;
	store \$NumberOfNgrams, $noNGramsStorage;
}

sub ReloadMemory {
	DEBUG("Loading from memory");
	DEBUG("NWords => $nWordsStorage");
	DEBUG("PC => $probabilityCacheStorage");
	DEBUG("ABL => $allButLastStorage");
	DEBUG("No => $noNGramsStorage");
	if( 	-e $nWordsStorage && 
		-e $probabilityCacheStorage &&
		-e $allButLastStorage &&
		-e $noNGramsStorage
	)
	{
		DEBUG("Files exist - retrieving");
		$N = retrieve($nWordsStorage);
		$P= retrieve($probabilityCacheStorage);
		$A= retrieve($allButLastStorage);
		$No = retrieve($noNGramsStorage);
		DEBUG("$N - $P - $A - $No");
		if($N != undef && $P != undef && $A != undef && $No != undef)
		{
			%NWords = %$N;
			%ProbabilityCache = %$P;
			%AllButLast = %$A;
			$NumberOfNGrams = $$No;
		}
	}
	&DumpState;
}

%PLUGIN_INFO = (
	perl_api_version => 2,
	name => "Harry's Markov Plugin",
	version => "0.1",
	summary => "Learns from what you write, and generates sentences.",
	description => "Generates sentences based on what you've said to people in the past.",
	author => "Harry Rose <htr106\@ecs.soton.ac.uk>",
	url => "http://harryrose.org",
	load => "plugin_load",
	unload => "plugin_unload"
);

sub DEBUG { my ($message) = @_;
	Purple::Debug::info($plugname,"$message\n");
}
	
sub plugin_init {
	return %PLUGIN_INFO;
}

sub plugin_load { my ($plugin) = @_;
	DEBUG("Plugin loaded");
	&ReloadMemory();
	my $accounts_handle = Purple::Conversations::get_handle();
	Purple::Signal::connect($accounts_handle, "sent-im-msg",$plugin,\&sent_callback,"");
	Purple::Signal::connect($accounts_handle, "sending-im-msg",$plugin,\&sending_callback,"");

	# Receiving is a bit scary.  Sort this out later.
	#Purple::Signal::connect($accounts_handle, "received-im-msg",$plugin,\&received_callback,"");
}

sub sending_callback{ my($account,$to,$message) = @_;

	if($message =~ m/^@([^\s].*)$/)
	{
		if(! exists($SendingStatus{$to}) ||  $SendingStatus{$to} == 0)
		{
			$_[2] = '';
			my $im = getChatWithUser($to);
			DEBUG("SENDING From account $account msg: '$message' to: $to");
			my $seed = $1;
			if($1 eq "@")
			{
				$seed = &getRandomKey(\%AllButLast);
			}
			elsif ($1 =~ m/^\?(.*)$/)
			{
				if($1 eq "stats")
				{
					$command = $im->write("Markov","Number of NGrams = ".scalar(keys(%NWords)),0,0);
				}
				else
				{
					&writeHelpToWindow($im);
				}
				return;
			}
			elsif ($1 =~ m/^\#(.*)$/)
			{
				#ignore this message
				$SendingStatus{$to} = 1;
				$im->send("$1");
				return;
			}

			DEBUG("SEED $seed");
			$SendingStatus{$to} = 1;
			$gs = &generateSentence($seed);
		
			$im->send("<font color=\"$SendColourHex\">$gs</font>");
		}
	}
}

sub getChatWithUser{ my ($username) = @_;
	my $im;
	my @convos = Purple::get_conversations();

	foreach (@convos)
	{
		if($_->get_name() eq $username)
		{
			return $_->get_im_data();
		}
	}
}

sub writeHelpToWindow { my ($imdata) = @_;

	my $help = <<HELP;
Markov - Learns vocabulary from messages you sends to folk and generates sentences based on that vocabulary.

Commands
	@[words]	Send a sentence that starts with the specified words
	@@		Send a sentence that starts with randomly chosen words
	@?stats		Write some statistics to your window (no data is sent)
	@?help		Prints this help
	@#[whatever]	Send [whatever] to the chat without logging it to memory.
HELP
	$imdata->write("Markov Help",$help,0,0);
}

sub plugin_unload { my ($plugin) = @_;
	&DumpState();
	&SaveMemory();
	DEBUG("Plugin unloaded");
}

sub sent_callback{ my ($from,$to,$msg) = @_;
	DEBUG("\n>>>>> SENT >>>>>\n");
	DEBUG("Sending '$msg' from '$from' to '$to'");
	if(!exists($SendingStatus{$to}) || $SendingStatus{$to} == 0)
	{

		@sentences = &sanitiseSentences($msg);
		
		foreach (@sentences)
		{
			DEBUG("Processing sentence $_");
			&processSentence($_);
		}
	#	DEBUG("Sanitised is ".Dumper(@sentences));
	#	DEBUG("Generated Sentence ".&generateSentence("$beginToken how are"));
	}
	$SendingStatus{$to} = 0;
}

sub sanitiseSentences { my ($input) = "@_";
	$input =~ s/<[^>]+>//g;
	$input =~ s![a-zA-Z]+://[^\s]+!!g;
	my @sentences = split(/\./,$input);
	my @output;
	foreach (@sentences)
	{
		push(@output,&sanitiseSentence($_));
	}

	return @output;
}

sub sanitiseSentence { my ($sentence) = "@_";
	$sentence = lc $sentence;
	$sentence =~ s/[^a-zA-Z':)(;0-9&]/ /g;
	$sentence = "$beginToken $sentence $endToken";
	$sentence =~ s/\s+/ /g;

	return $sentence;
}

sub processSentence { my ($sentence) = @_;
	my @words = split(/\s+/,$sentence);
	DEBUG('@words');	
	DEBUG(Dumper (@words));

	for(my $i = 0; $i+$nGramSize <= scalar(@words); $i++)
	{
		my $nwords="";
		my $mwords=""; #m being one less than n...

		for($j = 0; $j < $nGramSize-1; $j++)
		{
			$mwords .= (($j > 0)? " " :"" ).$words[$i+$j];
		}
		$nwords = "$mwords ".$words[$i+$nGramSize-1];

		DEBUG("nwords = '$nwords'");
		DEBUG("mwords = '$mwords'");
		$NWords{$nwords} = 0 if not exists $NWords{$nwords};
		$NWords{$nwords} ++;
	
		$AllButLast{$mwords} = 0 if not exists $AllButLast{$mwords};
		$AllButLast{$mwords} ++;

		$NumberOfNgrams ++;

		&updateProbabilityCache($nwords);
	}
}

sub updateProbabilityCache{ my ($ngram) = @_;
	DEBUG("UPDATING PROBABILITY CACHE");
	$ngram =~ m/^(.*)\s[^\s]+$/;
	my $allButLast = $1;
	DEBUG("ABL");
	DEBUG( Dumper $allButLast);

	$ngram =~ m/([^\s]+)$/;
	
	my $last = $1;
	$ProbabilityCache{$allButLast} = {} if not exists $ProbabilityCache{$allButLast};
	$ProbabilityCache{$allButLast}->{$last} = 1;
	
	foreach (keys %{$ProbabilityCache{$allButLast}})
	{
		my $tngram = $allButLast." $_";
		my $prob = $NWords{$tngram}/$AllButLast{$allButLast};
		DEBUG("Looking at '$tngram' PROBABILITY IS $prob");
		$ProbabilityCache{$allButLast}->{$_} = $prob;
	}
}

sub DumpState{
}

sub generateSentence{ my ($inputSeed) = @_;
	DEBUG("Generating a sentence");
	my $sentence = "$inputSeed";

	my $nextWord = "";

	DEBUG("NW $nextWord  ET $endToken");
	#get te last n words
	for(my $i = 0; $i < 100 && $nextWord ne $endToken; $i++)
	{
		DEBUG("Sentence so far: '$sentence'");
		my @words = split(/[\s]+/,$sentence);

		my $lastN = "";

		for(my $i = -$nGramSize+1; $i < 0; $i ++)
		{
			$lastN .= $words[$i].(($i == -1)? "" : " ");
		}
	
		DEBUG("Last $nGramSize words are '$lastN'");

		if(!exists($ProbabilityCache{$lastN}))
		{
			DEBUG("'$lastN' Has not been seen before, ".$ProbabilityCache{$lastN});
			$nextWord = $endToken;
			next;
		}
		$nextWord = &pickAWord($lastN);
		if($nextWord eq $endToken){ last;}
		$sentence .= " $nextWord";
		DEBUG("Next Word is $nextWord");
	}

	DEBUG("Sentence generation complete : '$sentence'");
	return "$sentence";
}

sub pickAWord{ my ($lastN) = @_;
	$rand = rand();

	$potential = "__END__";

	DEBUG("Picking a word. Rand = $rand");
	$sumSoFar = 0;
	foreach (keys(%{$ProbabilityCache{$lastN}}))
	{
		if($_ eq "") { next; }
		my $v;
		$v= $ProbabilityCache{$lastN}->{$_};
		DEBUG("Considering '$_' v = $v, potential = ".$ProbabilityCache{$lastN}->{$potential});
		$sumSoFar+= $v;
		if($sumSoFar > $rand)
		{
			#choose this word and break the loop
			$potential = $_;
			last;
		}
	}

	return $potential;
}

sub getRandomKey { my ($hashRef) = @_;
	my @keys = keys %$hashRef;
	return $keys[rand(scalar(@keys))];
}

#sub received_callback{ my($to,$from,$msg) = @_;
#	print "\n<<<<<< RECV <<<<<<\n";
#	DEBUG("TestPlugin: plugin_load() Received '$msg' from '$from' to '$to'");
#	print Dumper $data;
#}


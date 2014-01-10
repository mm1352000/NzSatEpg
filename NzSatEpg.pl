# Copyright 2013, mm1352000

# This file is part of NzSatEpg.

# NzSatEpg is free software: you can redistribute it and/or modify it under the
# terms of the GNU Affero Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.

# NzSatEpg is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero Public License for more details.

# You should have received a copy of the GNU Affero Public License along with
# NzSatEpg. If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;

package XmlTv::NzSatEpg;

use DateTime;
use HTML::Entities qw(decode_entities);
use LWP::UserAgent;

use Channels::AmazingDiscoveries;
use Channels::ArirangWorld;
use Channels::Daystar;
use Channels::Ewtn;
use Channels::GodTv;
use Channels::HopeChannel;
use Channels::Inspiration;
use Channels::NhkWorld;
use Channels::PressTv;
use Channels::RussiaToday;
use Channels::Tbn;
use Channels::ThreeAbn;


#==================================================================================================
# Important Variables
#==================================================================================================
# This is the full path to the output file.
$::outputFile = 'C:\Program Files\XMLTV\tvguide.xml';

# This is the directory that is used to store the files that are downloaded by this script.
$::tempPath = 'C:\Program Files\XMLTV';

# This is the full path to the debug file. Note that debug is only printed to this file if the
# environment variable 'DEBUG_NZSATEPG' has been set.
$::debugFile = '&STDOUT';

# This is the timeout period (in seconds) used by the global web user agent.
$::webTimeout = 30;

# This is the common time zone which all schedule data times will be converted to.
$::targetTimeZone = 'Pacific/Auckland';

# This is the number of days of data, starting from today in the target time zone, which will be
# gathered (wherever possible).
$::daysToGrab = 14;

%::monthMap = (
    'January'    => 1,
    'Jan'        => 1,
    'February'    => 2,
    'Feb'        => 2,
    'March'        => 3,
    'Mar'        => 3,
    'April'        => 4,
    'Apr'        => 4,
    'May'        => 5,
    'May'        => 5,
    'June'        => 6,
    'Jun'        => 6,
    'July'        => 7,
    'Jul'        => 7,
    'August'    => 8,
    'Aug'        => 8,
    'September'    => 9,
    'Sep'        => 9,
    'October'    => 10,
    'Oct'        => 10,
    'November'    => 11,
    'Nov'        => 11,
    'December'    => 12,
    'Dec'        => 12
);

#===============================================================================================
# Main Section
#===============================================================================================
# Open all the streams that this script uses.
$| = 1;
open(OUTPUT, ">$::outputFile") || die __LINE__ . ": Failed to open the output stream for writing.\n";
if (!exists $ENV{'DEBUG_NZSATEPG'}) {
    $::debugFile = ($^O =~ m/MSWin/) ? 'NUL' : '/dev/null';
}
open($::dbg, ">$::debugFile") || die __LINE__ . ": Failed to open the debug stream for writing.\n";
$::dbg->autoflush(1);

# Pretend to be a Firefox browser. The 3ABN website rejects our requests if we don't set the agent.
$::wua = LWP::UserAgent->new(timeout => $::webTimeout);
$::wua->agent("Mozilla/5.0 (Windows NT 5.1; rv:18.0) Gecko/20100101 Firefox/18.0");

$::startDate = DateTime->today()->set_time_zone($::targetTimeZone)->truncate(to => 'day');
$::endDate = $::startDate->clone()->add(days => $::daysToGrab);

print $::dbg "Starting data grab for $::daysToGrab days ($::startDate to $::endDate) in time zone $::targetTimeZone...\n";

print OUTPUT "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n<!DOCTYPE tv SYSTEM \"dtds/xmltv.dtd\">\n\n<tv>\n";


print "NzSatEpg v1.0 alpha, AGPL licence, copyright 2013 mm1352000\n";
print "Start grabbing...\n";
printChannelData(XmlTv::NzSatEpg::Channels::AmazingDiscoveries::getChannelData());
printChannelData(XmlTv::NzSatEpg::Channels::ArirangWorld::getChannelData());
printChannelData(XmlTv::NzSatEpg::Channels::Daystar::getChannelData());
printChannelData(XmlTv::NzSatEpg::Channels::Ewtn::getChannelData());
printChannelData(XmlTv::NzSatEpg::Channels::GodTv::getChannelData());
printChannelData(XmlTv::NzSatEpg::Channels::HopeChannel::getChannelData());
printChannelData(XmlTv::NzSatEpg::Channels::Inspiration::getChannelData());
printChannelData(XmlTv::NzSatEpg::Channels::NhkWorld::getChannelData());
printChannelData(XmlTv::NzSatEpg::Channels::PressTv::getChannelData());
printChannelData(XmlTv::NzSatEpg::Channels::RussiaToday::getChannelData());
printChannelData(XmlTv::NzSatEpg::Channels::Tbn::getChannelData());
printChannelData(XmlTv::NzSatEpg::Channels::ThreeAbn::getChannelData());
print "Grabbing completed successfully!\n";

print OUTPUT "</tv>\n";
close(OUTPUT);

close($::dbg);




sub toHoursAndMinutes {

    my $rawTime = shift;
    my $hours;
    $rawTime =~ m/^\s*(\d+):(\d+)\s*([AP]M)?\s*$/;
    $hours = ($1 == 12) ? 0 : $1;
    $hours += 12 if (uc($3) eq 'PM');
    return ($hours, $2);
}

# This subroutine is used to tidy up the titles and descriptions that get put into the output file.
sub tidyText {

    my $text = shift || '';

    # Deal with links.
    $text =~ s/<a.*?href="([^"]*)".*?>\s*(.*?)\s*<\/a>/$2 ($1)/gi;

    # Replace newline, HTML break and multiple spaces with a single space.
    $text =~ s/(\r)?\n(\r)?/ /gs;
    $text =~ s/<br(\s*\/)?>(<br(\s*\/)?>)?/ /gi;
    $text =~ s/\s\s+/ /g;

    # Convert HTML entities (eg. &amp; &acute;) into characters.
    $text = decode_entities($text);

    # Some entities should be left alone.
    $text =~ s/&/&amp;/gi;
    $text =~ s/</&lt;/gi;
    $text =~ s/>/&gt;/gi;
    $text =~ s/"/&quot;/gi;

    # Encode unicode characters correctly.
    while ($text =~ m/(\P{IsASCII})/) {
        my $code = sprintf("%04x", ord($1));
        $text =~ s/\x{$code}/&#x$code;/g;
    }

    # Remove leading and trailing whitespace.
    $text =~ s/^\s*(.*?)\s*$/$1/s;
    return $text;
}

sub printChannelData {

    my ($data) = @_;

    return if (!defined $data);

    foreach my $channel (@$data) {
        printChannelEntry($channel);
        my $id = $channel->{'id'};
        my $schedule = $channel->{'schedule'};
        foreach my $prog (sort keys %$schedule) {
            printProgrammeEntry($id, $schedule->{$prog});
        }
    }
}

sub printChannelEntry {

    my ($channel) = @_;

    print OUTPUT "<channel id=\"" . $channel->{'id'} . "\">\n";
    print OUTPUT "\t<display-name>" . $channel->{'name'} . "</display-name>\n";
    if (exists $channel->{'url'}) {
        foreach my $url (@{$channel->{'url'}}) {
            print OUTPUT "\t<url>$url</url>\n"
        }
    }
    print OUTPUT "</channel>\n";
}

sub printProgrammeEntry {

    my ($channelId, $programme) = @_;

    print OUTPUT "<programme channel=\"$channelId\" start=\"" . $programme->{'start'} . '00" stop="' . $programme->{'end'} . "00\">\n";
    print OUTPUT "\t<title>" . tidyText($programme->{'title'}) .  "</title>\n";
    if (exists $programme->{'episode title'}) {
        print OUTPUT "\t<sub-title>" . tidyText($programme->{'episode title'}) .  "</sub-title>\n";
    }
    if (exists $programme->{'episode number'}) {
        foreach my $episodeNum (@{$programme->{'episode number'}}) {
            my ($system, $num) = split(/:/, $episodeNum);
            print OUTPUT "\t<episode-num system=\"$system\">$num</episode-num>\n";
        }
    }
    if (exists $programme->{'episode description'}) {
        print OUTPUT "\t<desc>" . tidyText($programme->{'episode description'}) . "</desc>\n";
    }
    if (exists $programme->{'description'} && $programme->{'description'} ne '') {
        print OUTPUT "\t<desc>" . tidyText($programme->{'description'}) . "</desc>\n";
    }
    if (exists $programme->{'url'}) {
        foreach my $url (@{$programme->{'url'}}) {
            print OUTPUT "\t<url>" . tidyText($url) . "</url>\n"
        }
    }
    if (exists $programme->{'host'} || exists $programme->{'producer'}) {
        print OUTPUT "\t<credits>\n";
        foreach my $host (@{$programme->{'host'}}) {
            print OUTPUT "\t\t<presenter>" . tidyText($host) . "</presenter>\n";
        }
        foreach my $producer (@{$programme->{'producer'}}) {
            print OUTPUT "\t\t<producer>" . tidyText($producer) . "</producer>\n";
        }
        print OUTPUT "\t</credits>\n";
    }
    if (exists $programme->{'category'}) {
        foreach my $category (@{$programme->{'category'}}) {
            print OUTPUT "\t<category>$category</category>\n";
        }
    }
    if (exists $programme->{'premiere'}) {
        print OUTPUT "\t<premiere>" . $programme->{'premiere'} . "</premiere>\n";
    }
    if (exists $programme->{'rating'}) {
        foreach my $rating (@{$programme->{'rating'}}) {
            my ($system, $value) = split(/:/, $rating);
            print OUTPUT "\t<rating system=\"$system\">$value</rating>\n";
        }
    }
    print OUTPUT "</programme>\n";
}

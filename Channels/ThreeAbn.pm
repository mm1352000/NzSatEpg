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

package XmlTv::NzSatEpg::Channels::ThreeAbn;

use DateTime;
use JSON;
use String::Similarity;

sub getChannelData {

    print $::dbg "3ABN: Starting data grab...\n";

    print $::dbg "3ABN: Grabbing programme descriptions...\n";
    my $response = $::wua->get('http://3abn.org/networks/3abn-tv/programs/');
    if ($response->is_error()) {
        print $::dbg '3ABN (' . __LINE__ . '): The request for the description HTML failed. ' . $response->status_line() . "\n";
        return undef;
    }

    if ($response->content !~ m/<h1>Program\s+Descriptions<\/h1>\s*(.*?)\s*<div\s+class="clearboth">/s) {
        print $::dbg '3ABN (' . __LINE__ . "): The description format has changed.\n";
        return undef;
    }
    my $html = $response->content;

    my %descriptions = ();
    while ($html =~ m/.*?<h4>\s*(.*?)\s*<\/h4>\s*<p>\s*(.*?)\s*<\/p>(.*)/s) {
        my ($progName, $progDesc) = ($1, $2);
        $html = $3;
        $descriptions{$progName} = $progDesc;
    }

    print $::dbg "3ABN: Grabbing the schedule...\n";
    my %schedule = ();
    my $prevProg = undef;
    my %progMatches = ();
    my %form = (
        'network' => 4                              # We're interested in the international feed.
        , 'local_timezone' => 'America/New_York'    # Use the native time zone for the schedule.
    );
    my $currentEstDate = $::startDate->clone()->set_time_zone('America/New_York');
    my $targetTzDate = $::startDate->clone();

    # For each day...
    while ($targetTzDate < $::endDate) {
        print $::dbg "3ABN:\tday $targetTzDate...\n";
        $form{'date'} = $currentEstDate->strftime("%Y-%m-%d");
        $response = $::wua->post('http://3abn.org/sabramedia/controller/read-schedule-xml.php', \%form);
        if ($response->is_error()) {
            print $::dbg '3ABN (' . __LINE__ . '): The request for the schedule HTML failed. ' . $response->status_line() . "\n";
            return undef;
        }

        if ($response->content !~ m/.*?"programs":\[(.*?)]\,/s) {
            print $::dbg '3ABN (' . __LINE__ . "): The schedule format has changed.\n";
            return undef;
        }
        $html = $1;

        # For each programme...
        foreach my $progString (split(/(?<=\})\,(?=\{)/, $html)) {
            # The programme data is actually JSON encoded.
            my $prog = from_json($progString);

            if (defined $prevProg) {
                my ($progStartHour, $progStartMinute) = XmlTv::NzSatEpg::toHoursAndMinutes($prevProg->{'Time'});
                my ($progEndHour, $progEndMinute) = XmlTv::NzSatEpg::toHoursAndMinutes($prog->{'Time'});
                my $progStartDateTime = $currentEstDate->clone()->set(hour => $progStartHour, minute => $progStartMinute)->set_time_zone($::targetTimeZone);
                my $progEndDateTime = $currentEstDate->clone()->set(hour => $progEndHour, minute => $progEndMinute)->set_time_zone($::targetTimeZone);

                # Add the previous programme to the schedule if shows within the window of interest.
                if ($progEndDateTime > $::startDate && $progStartDateTime < $::endDate) {
                    my $progStartString = $progStartDateTime->strftime('%Y%m%d%H%M');
                    my $p = {
                        'start' => $progStartString
                        , 'end' => $progEndDateTime->strftime('%Y%m%d%H%M')
                        , 'title' => $prevProg->{'Series'}
                        , 'episode number' => ['3ABN:' . $prevProg->{'ProgramCode'}]
                    };
                    if (exists $prevProg->{'Content'} && defined $prevProg->{'Content'} && $prevProg->{'Content'} ne '') {
                        $p->{'episode title'} = $prevProg->{'Content'};
                    }
                    if ($prevProg->{'Guests'} !~ m/^\s*$/) {
                        $p->{'host'} = [];
                        map { $_ =~ m/^\s*(.*?)\s*$/; push(@{$p->{'host'}}, $1); } split(/,/, $prevProg->{'Guests'});
                    }

                    # Attempt to match the programme with a description using the series name.
                    if (!exists $progMatches{$prevProg->{'Series'}}) {
                        $progMatches{$prevProg->{'Series'}} = undef;

                        my ($maxSim, $bestKey) = (0, '');
                        foreach my $dk (keys %descriptions) {
                            my $sim = similarity($dk, $prevProg->{'Series'});
                            if ($sim > $maxSim) {
                                $maxSim = $sim;
                                $bestKey = $dk;
                            }
                        }

                        # 0.65 is the magic matching threshold.
                        if ($maxSim > 0.65) {
                            #print $::dbg "3ABN: similarity match $maxSim, $prevProg->{'Series'}  $bestKey\n";
                            $progMatches{$prevProg->{'Series'}} = $bestKey;
                        }
                    }

                    if (defined $progMatches{$prevProg->{'Series'}}) {
                        $p->{'description'} = $descriptions{$progMatches{$prevProg->{'Series'}}};
                    }

                    $schedule{$progStartString} = $p;
                }
            }

            $prevProg = $prog;
        }

        $currentEstDate->add(days => 1);
        $targetTzDate->add(days => 1);
    }

    return [
        {
            'id' => '3abn.optus_d2.xmltv.org'
            , 'name' => '3ABN'
            , 'url' => [
                'http://3abn.org/'
            ]
            , 'schedule' => \%schedule
        }
    ];
}

1;
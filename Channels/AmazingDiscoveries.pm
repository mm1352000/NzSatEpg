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

package XmlTv::NzSatEpg::Channels::AmazingDiscoveries;

use DateTime;

sub getChannelData {

    print $::dbg "AD: Starting data grab...\n";

    # The AD schedule data is provided in the PST time zone (UTC-8). We have access to
    # approximately ten days of data.
    my $response = $::wua->get('http://amazingdiscoveries.org/amazing-discoveries-satellite-schedule');
    if ($response->is_error()) {
        print $::dbg 'AD (' . __LINE__ . '): The request for the schedule HTML failed. ' . $response->status_line() . "\n";
        return undef;
    }
    my $html = $response->content;

    my %schedule = ();
	my %prevProg = (
        'title' => ''
        , 'episode title' => ''
        , 'host' => undef
        , 'start' => undef
    );

    # For each day...
    while ($html =~ m/.*?<h2>Amazing\sDiscoveries\sSatellite\sSchedule\s<br\s\/>\s*for\s[^\s]+\s*-\s+([^\s]+)\s+(\d+)\,\s+(\d+).*?(<tr>\s*<td>0:00 AM<\/td>.*?<\/table>)(.*)/s) {
        my ($monthName, $day, $year, $dayHtml) = ($1, $2, $3, $4);
        $html = $5;

        # For each programme...
        while ($dayHtml =~ m/.*?<tr>\s*<td>(.*?)<\/td>\s*<td><\/td>\s*<td>(.*?)<\/td>\s*<td>(.*?)<\/td>\s*<td>(.*?)<\/td>(.*)/s) {
            my ($rawTime, $progName, $progSpeaker, $progSeries) = ($1, $2, $3, $4);
            $dayHtml = $5;

            
            # The Amazing Discovery schedule included invalid times for the March 2013 DST change.
            my ($progStartHours, $progStartMinutes) = XmlTv::NzSatEpg::toHoursAndMinutes($rawTime);
            my $currentTargetTzDateTime = undef;
            eval {
                $currentTargetTzDateTime = DateTime->new(year => $year, month => $::monthMap{$monthName}, day => $day, hour => $progStartHours, minute => $progStartMinutes, time_zone => 'America/Los_Angeles');
                $currentTargetTzDateTime->set_time_zone($::targetTimeZone);
            };
            if ($@) {
                print $::dbg 'AD (' . __LINE__ . "): Warning, invalid time. Programme at $day $monthName $year $progStartHours:$progStartMinutes will be skipped.\n";
                next;
            }

            # Add the previous programme to the schedule if shows within the window of interest.
            if ($prevProg{'title'} ne '' && $currentTargetTzDateTime > $::startDate && $prevProg{'start'} < $::endDate) {
                my $progStartString = $prevProg{'start'}->strftime("%Y%m%d%H%M");
                my $p = {
                    'title' => $prevProg{'title'}
                    , 'start' => $progStartString
                    , 'end' => $currentTargetTzDateTime->strftime("%Y%m%d%H%M")
                };
                if (defined $prevProg{'host'}) {
                    $p->{'host'} = $prevProg{'host'};
                }
                if (defined $prevProg{'episode title'}) {
                    $p->{'episode title'} = $prevProg{'episode title'};
                }

                $schedule{$progStartString} = $p;
            }

            %prevProg = (
                'title' => $progName
                , 'host' => undef
                , 'start' => $currentTargetTzDateTime
            );
            if ($progSpeaker ne '' && $progSpeaker ne '&nbsp;') {
                $prevProg{'host'} = [$progSpeaker];
            }
            if ($progSeries ne '' && $progSeries ne '&nbsp;') {
                $prevProg{'title'} = $progSeries;
                $prevProg{'episode title'} = $progName;
            }
        }
    }

    return [
        {
            'id' => 'amazing_discoveries.optus_d2.xmltv.org'
            , 'name' => 'Amazing Discoveries'
            , 'url' => [
                'http://amazingdiscoveries.org/amazing-discoveries-on-satellite'
            ]
            , 'schedule' => \%schedule
        }
    ];
}

1;
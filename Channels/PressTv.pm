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

package XmlTv::NzSatEpg::Channels::PressTv;

use DateTime;

sub getChannelData {

    print $::dbg "Press TV: Starting data grab...\n";

    # The Press TV schedule data can be retrieved in any time zone. We use GMT/UTC by convention.
    my %schedule = ();
    my $currentGmtDate = $::startDate->clone()->set_time_zone('UTC')->truncate(to => 'day');
    my $targetTzDate = $::startDate->clone();
	my %prevProg = (
        'title' => ''
        , 'start' => undef
        , 'description' => ''
    );
    while ($targetTzDate < $::endDate) {
        # Grab the data for the day.
        print $::dbg "Press TV:\tday $targetTzDate...\n";

        my $response = $::wua->get('http://edition.presstv.ir/callback/sch/?t=0&dst=0&d=' . $currentGmtDate->strftime('%Y-%m-%d'));
        if ($response->is_error()) {
            print $::dbg 'Press TV (' . __LINE__ . '): The request for the schedule HTML failed. ' . $response->status_line() . "\n";
            return undef;
        }
        my $html = $response->content;

        # For each programmme...
        while ($html =~ m/.*?<tr\s+class='ev'><td><div\s+class='name'>(.*?)<\/div><div\s+class='desc'>(.*?)<\/div><\/td><td\s+class='fr'>(\d{2}):(\d{2})<\/td><\/tr>(.*)/s) {
            my ($progTitle, $progDesc, $progStartHour, $progStartMinute) = ($1, $2, $3, $4);
            $html = $5;

            $currentGmtDate->set(hour => $progStartHour, minute => $progStartMinute);

            if ($progTitle eq $prevProg{'title'}) {
                next;
            }

            # Add the previous programme to the schedule if it shows within the window of interest.
            my $currentTargetTzDateTime = $currentGmtDate->clone()->set_time_zone($::targetTimeZone);
            if ($prevProg{'title'} ne '' && $currentTargetTzDateTime > $::startDate && $prevProg{'start'} < $::endDate) {
                my $progStartString = $prevProg{'start'}->strftime('%Y%m%d%H%M');
                $schedule{$progStartString} = {
                    'start' => $progStartString
                    , 'end' => $currentTargetTzDateTime->strftime('%Y%m%d%H%M')
                    , 'title' => $prevProg{'title'}
                    , 'description' => $prevProg{'description'}
                };
            }

            %prevProg = (
                'title' => $progTitle
                , 'start' => $currentTargetTzDateTime
                , 'description' => $progDesc
            );
        }

        $currentGmtDate->add(days => 1)->truncate(to => 'day');
        $targetTzDate->add(days => 1);
    }

    # We miss the last programme - tough cookies.

    return [
        {
            'id' => 'press_tv.optus_d2.xmltv.org'
            , 'name' => 'Press TV'
            , 'url' => [
                'http://www.presstv.ir/'
            ]
            , 'schedule' => \%schedule
        }
    ];
}

1;

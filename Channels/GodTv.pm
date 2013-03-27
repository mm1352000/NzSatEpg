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

package XmlTv::NzSatEpg::Channels::GodTv;

use DateTime;
use JSON;

sub getChannelData {

    print $::dbg "God TV: Starting data grab...\n";

    # Get the seven day schedule. The schedule is provided in the AEST timezone (UTC+10). There is
    # no way of controlling which 7 days we get so all we can do is work with what we're given.
    my $response = $::wua->get('http://www.god.tv/weeklyschedule?region=123');
    if ($response->is_error()) {
        print $::dbg 'God TV (' . __LINE__ . '): The request for the schedule HTML failed. ' . $response->status_line() . "\n";
        return undef;
    }
    my $html = $response->content;

    # Set up reference dates based on the date of the first day in the schedule.
    if ($response->content !~ m/.*?class="full_sched_date">.*?(\d+)\s*(.+?)\s*<\/div>\s*(.+)/s) {
        print $::dbg 'God TV (' . __LINE__ . "): The schedule format has changed.\n";
        return undef;
    }
    my $currentAestDate = DateTime->now(time_zone => 'Australia/Sydney')->set(month => $::monthMap{$2}, day => $1);

    # Throw in a dummy programme on the end of the schedule to save having to do special stuff to
    # catch the (real) last programme of the week.
    $html = "$3 class=\"full_sched_start\">06:00 class=\"full_sched_title\">Dummy<\/div> class=\"full_sched_description\"><\/div>";

    my %schedule = ();
	my %prevProg = (
        'title' => ''
        , 'start' => undef
        , 'description' => ''
    );

    # For each programme...
    while ($html =~ m/.*?class="full_sched_start">\s*(\d+):(\d+).+?class="full_sched_title">\s*(.*?)\s*<\/div>.+?class="full_sched_description">\s*(.*?)\s*<\/div>(.*)/s) {
        my ($progStartHours, $progStartMinutes, $progTitle, $progDesc) = ($1, $2, $3, $4 || '');
        $html = $5;

        # The guide starts at 6 AM rather than midnight, which means we have to catch the midnight
        # crossings in order to keep the date correct.
        if ($currentAestDate->hour > $progStartHours) {
            $currentAestDate->add(days => 1);
        }
        $currentAestDate->set(hour => $progStartHours, minute => $progStartMinutes);

        if ($progTitle eq $prevProg{'title'} && $progDesc eq $prevProg{'description'}) {
            next;
        }

        # Add the previous programme to the schedule if shows within the window of interest.
        my $currentTargetTzDateTime = $currentAestDate->clone()->set_time_zone($::targetTimeZone);
        if (defined $prevProg{'start'} && $currentTargetTzDateTime > $::startDate && $prevProg{'start'} < $::endDate) {
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

    return [
        {
            'id' => 'god_tv.optus_d2.xmltv.org'
            , 'name' => 'God TV'
            , 'url' => [
                'http://www.god.tv/'
            ]
            , 'schedule' => \%schedule
        }
    ];
}

1;
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

package XmlTv::NzSatEpg::Channels::RussiaToday;

use DateTime;

sub getChannelData {

    print $::dbg "RT: Starting data grab...\n";

    # The Russia Today schedule data is provided in the Europe/Moscow time zone (UTC+4).
    my %schedule = ();
    my $currentMoscowDate = $::startDate->clone()->set_time_zone('Europe/Moscow')->truncate(to => 'day');
    my $targetTzDate = $::startDate->clone();
    my %descriptions = ();
	my %prevProg = (
        'title' => ''
        , 'start' => undef
        , 'url' => ''
    );
    while ($targetTzDate < $::endDate) {
        # Grab the data for the day.
        print $::dbg "RT:\tday $targetTzDate...\n";

        my $response = $::wua->get('http://rt.com/programs/schedule/' . $currentMoscowDate->strftime('%Y-%m-%d'));
        if ($response->is_error()) {
            print $::dbg 'RT (' . __LINE__ . '): The request for the schedule HTML failed. ' . $response->status_line() . "\n";
            return undef;
        }

        # Cut to the relevant content.
        if ($response->content !~ m/<div\s+class="cont-wp\s+table">\s*<table>\s*<tbody>\s*(.*?)\s*<\/tbody>/s) {
            print $::dbg 'RT (' . __LINE__ . "): The schedule format has changed.\n";
            return undef;
        }
        my $html = $1;

        # For each programmme...
        while ($html =~ m/.*?<tr>\s*<td\s+class=""><strong><strong>(\d+):(\d+)<\/strong><\/strong>\s*<span[^>]*>([ap]m)<\/span><\/td>\s*<td><a\s+href="([^"]+)"[^>]*?>\s*(.*?)\s*<\/a><\/td>(.*)/s) {
            my ($hour, $minute, $amPm, $progUrl, $progTitle) = ($1, $2, $3, "http://rt.com$4", $5);
            $html = $6;

            my ($progStartHour, $progStartMinute) = XmlTv::NzSatEpg::toHoursAndMinutes("$hour:$minute $amPm");
            $currentMoscowDate->set(hour => $progStartHour, minute => $progStartMinute);

            if ($progTitle eq $prevProg{'title'}) {
                next;
            }

            # Grab a description for the programme if we don't have one already.
            if (!exists $descriptions{$progUrl}) {
                $response = $::wua->get($progUrl);
                if ($response->is_success()) {
                    # TODO integrate the episode details
                    if ($response->content =~ m/.*?<p><p>\s*(.*?)\s*<\/p><\/p>.*/si) {
                        $descriptions{$progUrl} = $1;
                    }
                    elsif ($response->content =~ m/<meta\s+name="description" content="([^"]*)"/s) {
                        $descriptions{$progUrl} = $1;
                    }
                }
            }

            # Add the previous programme to the schedule if shows within the window of interest.
            my $currentTargetTzDateTime = $currentMoscowDate->clone()->set_time_zone($::targetTimeZone);
            if ($prevProg{'title'} ne '' && $currentTargetTzDateTime > $::startDate && $prevProg{'start'} < $::endDate) {
                my $progStartString = $prevProg{'start'}->strftime('%Y%m%d%H%M');
                my $p = {
                    'start' => $progStartString
                    , 'end' => $currentTargetTzDateTime->strftime('%Y%m%d%H%M')
                    , 'title' => $prevProg{'title'}
                    , 'url' => [$prevProg{'url'}]
                };
                if (exists $descriptions{$prevProg{'url'}}) {
                    $p->{'description'} = $descriptions{$prevProg{'url'}};
                }
                $schedule{$progStartString} = $p;
            }

            %prevProg = (
                'title' => $progTitle
                , 'start' => $currentTargetTzDateTime
                , 'url' => $progUrl
            );
        }

        $currentMoscowDate->add(days => 1)->truncate(to => 'day');
        $targetTzDate->add(days => 1);
    }

    # We miss the last programme - tough cookies.

    return [
        {
            'id' => 'russia_today.optus_d2.xmltv.org'
            , 'name' => 'Russia Today'
            , 'url' => [
                'http://rt.com/'
            ]
            , 'schedule' => \%schedule
        }
    ];
}

1;
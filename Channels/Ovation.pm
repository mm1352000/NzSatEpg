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

package XmlTv::NzSatEpg::Channels::Ovation;

use DateTime;

sub getChannelData {

    print $::dbg "Ovation: Starting data grab...\n";

    # The Ovation schedule data is provided in the AEST time zone (UTC+10). We have access to
    # approximately eight days of data.
    my %schedule = ();
    my $referenceDateTime = undef;
    my $prevStartDateTime = undef;
    for (my $day = 1; $day < 9; $day++) {
        my $response = $::wua->get("http://www.dv1.com.au/tvguideschedule_new.php?buttonNumber=$day");
        if ($response->is_error()) {
            print $::dbg 'Ovation (' . __LINE__ . '): The request for the schedule HTML failed. ' . $response->status_line() . "\n";
            return undef;
        }
        my $html = $response->content;

        if ($html !~ m/(.*?)<table width="100%" border="0" cellpadding="0" cellspacing="0">\s*<tr>\s*(<td width="20%" align="left" valign="top"><div class="listingTime">.*?)<\/table>/s) {
            print $::dbg 'Ovation (' . __LINE__ . "): The schedule format has changed.\n";
            return undef;
        }
        print $::dbg "Ovation:\tday $day...\n";
        my ($dateHtml, $scheduleHtml) = ($1, $2);

        if ($dateHtml !~ m/<span class="buttonDaySelected"><a href="\/tvguideschedule_new.php\?buttonNumber=\d">[^\s]+\s+(\d+)\s+([^\s]+)<\/a><\/span>/) {
            print $::dbg 'Ovation (' . __LINE__ . "): The schedule format has changed.\n";
            return undef;
        }

        if (!defined $referenceDateTime) {
            $referenceDateTime = DateTime->today(time_zone => 'Australia/Sydney')->set(day => $1, month => $::monthMap{$2}, hour => 0, minute => 0);
            # Handle the case where the first month in the schedule is in a different year to the
            # current date. For example, reading the schedule for December in January or later.
            if (($referenceDateTime - DateTime->today())->months() > 6) {
                $referenceDateTime->add(years => -1);
            }
        }

        # For each programme...
        while ($scheduleHtml =~ m/.*?class="listingTime">\s*([^<]+)<\/div>.*?class="listingHeading1">\s*(.*?)\s*<\/div>.*?class="listingHeading3">Classification:\s+\[([^\]]+)\]<\/div>.*?class="listingBody">\s*(.*?)\s*<\/div>(.*)/s) {
            my ($progStartTime, $progTitle, $rating, $progDesc) = ($1, $2, $3, $4);
            $scheduleHtml = $5;

            my ($progStartHour, $progStartMinute) = XmlTv::NzSatEpg::toHoursAndMinutes($progStartTime);
            my $startDateTime = $referenceDateTime->clone()->set(hour => $progStartHour, minute => $progStartMinute)->set_time_zone($::targetTimeZone);
            if ($startDateTime < $::endDate) {
                my $startDateTimeString = $startDateTime->strftime('%Y%m%d%H%M');
                my $p = {
                    'title' => $progTitle
                    , 'start' => $startDateTimeString
                    , 'description' => $progDesc
                };
                if ($rating ne 'NC') {
                    $p->{'rating'} = ["MPAA:$rating"];
                }
                $schedule{$p->{'start'}} = $p;

                # Set the end time on the previous programme, or delete it if it doesn't cover part
                # of the window of interest.
                if (defined $prevStartDateTime && exists $schedule{$prevStartDateTime}) {
                    if ($startDateTime <= $::startDate) {
                        delete $schedule{$prevStartDateTime};
                    }
                    else {
                        $schedule{$prevStartDateTime}->{'end'} = $startDateTimeString;
                    }
                }

                $prevStartDateTime = $startDateTimeString;
            }
            else {
                $prevStartDateTime = undef;
            }
        }
        $referenceDateTime->add(days => 1);
    }

    # Delete the last programme if we weren't able to get an end time for it.
    if (defined $prevStartDateTime && !exists $schedule{$prevStartDateTime}->{'end'}) {
        delete $schedule{$prevStartDateTime};
    }
 
    return [
        {
            'id' => 'ovation.optus_d2.xmltv.org'
            , 'name' => 'Ovation'
            , 'url' => [
                'http://www.ovationchannel.com.au/'
            ]
            , 'schedule' => \%schedule
        }
    ];
}

1;
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

package XmlTv::NzSatEpg::Channels::ArirangWorld;

use DateTime;

sub getChannelData {

    print $::dbg "Arirang: Starting data grab...\n";

    # The Arirang world schedule shows Monday..Sunday with Seoul time.
    my %schedule = ();
    my $dataFinished = 0;
    my $currentSeoulDate = $::startDate->clone()->set_time_zone('Asia/Seoul')->truncate(to => 'day');
    $currentSeoulDate->add(days => -$currentSeoulDate->day_of_week() + 1);
    my $prevStartDateTime = undef;
    while ($currentSeoulDate->clone()->set_time_zone($::targetTimeZone) < $::endDate) {
        my $weekStart = $currentSeoulDate->strftime('%Y-%m-%d');
        my $response = $::wua->get("http://www.arirang.co.kr/Tv/TV_Index.asp?MType=S&Channel=1&F_Date=$weekStart");
        if ($response->is_error()) {
            print $::dbg 'Arirang (' . __LINE__ . '): The request for the schedule HTML failed. ' . $response->status_line() . "\n";
            return undef;
        }
        my $html = $response->content;
        print $::dbg "Arirang: Processing the schedule for week $weekStart...\n";

        # For each day...
        my $d = 1;
        while ($html =~ m/.*?<table.*?summary="TV\s+Schedule">.*?<tbody>(.*?)<\/tbody>(.*)/s) {
            print $::dbg "Arirang:\tday " . $d++ . "...\n";
            my $dayHtml = $1;
            $html = $2;
            if ($dayHtml =~ m/^\s*$/s) {
                $dataFinished = 1;
                last;
            }

            # For each programme...
            while ($dayHtml =~ m/.*?<tr>\s*<td>(\d+):(\d+)(<\!--\/\/-\d+:\d+-->)?<\/td>\s*<td>\d+:\d+(<\!--\/\/-\d+:\d+-->)?<\/td>\s*<td\s+class="txt_left"><a\s+href="([^"]+)">([^<]*?)<\/a><\/td>\s*<td>(.*?)<\/td>(.*?)<\/tr>(.*)/s) {
                my ($progStartHours, $progStartMinutes, $progUrl, $progTitle, $vodLink, $firstRunHtml) = ($1, $2, $5, $6, $7, $8);
                $dayHtml = $9;

                my $startDateTime = $currentSeoulDate->clone()->set(hour => $progStartHours, minute => $progStartMinutes)->set_time_zone($::targetTimeZone);
                if ($startDateTime < $::endDate) {
                    my $startDateTimeString = $startDateTime->strftime('%Y%m%d%H%M');
                    my $p = {
                        'title' => $progTitle
                        , 'start' => $startDateTimeString
                    };
                    if ($vodLink =~ m/.*?<a\s+href="([^"]+)"/) {
                        $p->{'url'} = ["http://www.arirang.co.kr/Tv/$progUrl", "http://www.arirang.co.kr/Tv/$1"];
                    }
                    else {
                        $p->{'url'} = ["http://www.arirang.co.kr/Tv/$progUrl"];
                    }
                    if (defined $firstRunHtml && $firstRunHtml =~ m/firstrun/) {
                        $p->{'premiere'} = 'First showing in current run.';
                    }
                    $schedule{$p->{'start'}} = $p;

                    # Set the end time on the previous programme, or delete it if it doesn't cover
                    # part of the window of interest.
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
            $currentSeoulDate->add(days => 1);
        }

        last if ($dataFinished);
    }

    # Delete the last programme if we weren't able to get an end time for it.
    if (defined $prevStartDateTime && !exists $schedule{$prevStartDateTime}->{'end'}) {
        delete $schedule{$prevStartDateTime};
    }

    return [
        {
            'id' => 'arirang.intelsat_19.xmltv.org'
            , 'name' => 'Arirang World'
            , 'url' => [
                'http://www.arirang.co.kr/Tv/Tv_Index.asp'
            ]
            , 'schedule' => \%schedule
        }
    ];
}

1;

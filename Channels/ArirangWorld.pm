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
    my $referenceSeoulDate = $::startDate->clone()->set_time_zone('Asia/Seoul')->truncate(to => 'day');
    $referenceSeoulDate->add(days => -$referenceSeoulDate->day_of_week() + 1);
    my $referenceDate = $referenceSeoulDate->clone()->set_time_zone($::targetTimeZone);
    while ($referenceDate < $::endDate) {
        my $response = $::wua->get('http://www.arirang.co.kr/Tv/TV_Index.asp?MType=S&Channel=1&F_Date=' . $referenceSeoulDate->strftime('%Y-%m-%d'));
        if ($response->is_error()) {
            print $::dbg 'Arirang (' . __LINE__ . '): The request for the schedule HTML failed. ' . $response->status_line() . "\n";
            return undef;
        }
        my $html = $response->content;

        # For each day...
        while ($html =~ m/.*?<table.*?summary="TV\s+Schedule">.*?<tbody>(.*?)<\/tbody>(.*)/s) {
            my $dayHtml = $1;
            $html = $2;
            if ($dayHtml =~ m/^\s*$/s) {
                $dataFinished = 1;
                last;
            }

            # For each programme...
            while ($dayHtml =~ m/.*?<tr>.*?<td\s+class="txt_left"><a\s+href="([^"]+)">(.*?)<\/a>.*?<td>(.*?)<\/td>.*?<td>(\d+)<\/td>(.*?)<\/tr>(.*)/s) {
                my ($progUrl, $progTitle, $vodLink, $progLength, $firstRunHtml) = ($1, $2, $3, $4, $5);
                $dayHtml = $6;

                my $endDateTime = $referenceDate->clone()->add(minutes => $progLength);
                if ($endDateTime > $::startDate && $referenceDate < $::endDate) {
                    my $p = {
                        'title' => $progTitle
                        , 'start' => $referenceDate->strftime('%Y%m%d%H%M')
                        , 'end' => $endDateTime->strftime('%Y%m%d%H%M')
                    };
                    if ($vodLink =~ m/.*?<a\s+href="([^"]+)"/) {
                        $p->{'url'} = ["http://www.arirang.co.kr/Tv/$progUrl", "http://www.arirang.co.kr/Tv/$1"];
                    }
                    else {
                        $p->{'url'} = ["http://www.arirang.co.kr/Tv/$progUrl"];
                    }
                    if ($firstRunHtml =~ m/firstrun/) {
                        $p->{'premiere'} = 'First showing in current run.';
                    }
                    $schedule{$p->{'start'}} = $p;
                }
                $referenceDate = $endDateTime;
            }
        }

        last if ($dataFinished);
        $referenceSeoulDate->add(days => 7);
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

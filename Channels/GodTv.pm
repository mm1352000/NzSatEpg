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

    # Get the current schedule. The schedule is provided in the AEST timezone (UTC+10). There is no
    # way of controlling which days we get so all we can do is work with what we're given.
    my $response = $::wua->get('http://www.god.tv/schedule/api/view/123');
    if ($response->is_error()) {
        print $::dbg 'God TV (' . __LINE__ . '): The request for the schedule HTML failed. ' . $response->status_line() . "\n";
        return undef;
    }
    my $json = decode_json($response->content);

    # For each day...
    my %schedule = ();
    foreach my $k (keys $json->{'data'}) {
        # Not data for a day.
        next if ($k !~ m/^\d+$/);
        
        my $dayData = $json->{'data'}{$k};
        foreach my $p (@$dayData) {
            next if ($p->{'starttstamp'} eq '');

            my $startTime = DateTime->from_epoch(epoch => $p->{'starttstamp'})->set_time_zone($::targetTimeZone);
            if ($startTime < $::endDate) {
                my $endTime = DateTime->from_epoch(epoch => $p->{'endtstamp'})->set_time_zone($::targetTimeZone);
                if ($endTime > $::startDate) {
                    my $prog = {
                        'title' => $p->{'title'}
                        , 'start' => $startTime->strftime("%Y%m%d%H%M")
                        , 'end' => $endTime->strftime("%Y%m%d%H%M")
                    };
                    if ($p->{'speakers'} ne '') {
                        $prog->{'description'} = $p->{'speakers'};
                        if ($p->{'speakers'} ne 'live' && $p->{'speakers'} !~ m/[-:]/) {
                            $prog->{'host'} = [$p->{'speakers'}];
                        }
                    }
                    $schedule{$prog->{'start'}} = $prog;
                }
            }
        }
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
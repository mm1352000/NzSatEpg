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

package XmlTv::NzSatEpg::Channels::Ewtn;

use DateTime;
use DateTime::Format::Strptime;

sub getChannelData {

    print $::dbg "EWTN: Starting data grab...\n";

    # The EWTN schedule data is provided in the EST time zone (UTC-5). We have access to
    # approximately two months of data.
    my $response = $::wua->get('http://www.ewtn.com/multimedia/schedules.asp?sat=PACE');
    if ($response->is_error()) {
        print $::dbg 'EWTN (' . __LINE__ . '): The request for the schedule HTML failed. ' . $response->status_line() . "\n";
        return undef;
    }
    if ($response->content !~ m/var\sstrSIMSASP\s=\s"(.*?)";/s) {
        print $::dbg 'EWTN (' . __LINE__ . "): The schedule format has changed.\n";
        return undef;
    }
    my $html = $1;

    my %schedule = ();
    my $isFirst = 1;
    my @fields = ();
    my %progInfo = ();

    my $dtFormat = DateTime::Format::Strptime->new(
        pattern => '%m/%d/%Y %R'
        , locale => 'en_NZ'
        , time_zone => 'America/New_York'
    );
    foreach my $prog (split(/\|\|\|\|\|/, $html)) {
        # The first programme section contains the name/description of each programme information
        # field.
        if ($isFirst) {
            @fields = split(/\t/, $prog);
            $isFirst = 0;
            next;
        }

        # Split the programme information by field.
        my $f = 0;
        map { $progInfo{$fields[$f++]} = $_; } split(/\t/, $prog);

        my $progStartDateTime = $dtFormat->parse_datetime($progInfo{'Start Date'} . ' ' . $progInfo{'Start Time'});
        $progStartDateTime->set_time_zone($::targetTimeZone);

        # Ignore programmes that show outside the time window that we were asked to grab for.
        if ($progStartDateTime < $::startDate || $progStartDateTime > $::endDate) {
            next;
        }

        # Record the fields that we can handle.
        my $progStartString = $progStartDateTime->strftime('%Y%m%d%H%M');
        $progInfo{'Length'} =~ m/(\d+):(\d+)/;
        my $p = {
            'start' => $progStartString
            , 'end' => $progStartDateTime->add(hours => $1, minutes => $2)->strftime('%Y%m%d%H%M')
            , 'title' => $progInfo{'Program Name'}
        };
        if ($progInfo{'Title Name'} ne '') {
            $p->{'episode title'} = $progInfo{'Title Name'};
        }
        if ($progInfo{'Title Synopsis'} ne '' && $progInfo{'Title Synopsis'} ne $progInfo{'Program Synopsis'}) {
            $p->{'episode description'} = $progInfo{'Title Synopsis'};
        }
        if ($progInfo{'Program Synopsis'} ne '') {
            $p->{'description'} = $progInfo{'Program Synopsis'};
        }
        if ($progInfo{'Title Premiere Indicator (Current Schedule)'} eq 'P') {
            $p->{'premiere'} = 'First showing in current run.';
        }
        if ($progInfo{'Web Link'} ne '') {
            $p->{'url'} = [$progInfo{'Web Link'}];
        }
        if ($progInfo{'FCC Rating V-Chip Code(s)'} ne '') {
            $p->{'rating'} = ['FCC:' . $progInfo{'FCC Rating V-Chip Code(s)'}];
        }
        if ($progInfo{'Star (All)'} ne '') {
            # Not ideal, but we have no way to determine what role each person has.
            my @producers = split(/(?<!\s)\,(?!\s)/, $progInfo{'Star (All)'});
            $p->{'producer'} = \@producers;
        }
        if ($progInfo{'Program Genre'} ne '') {
            my @genres = split(/(?<!\s)\,(?!\s)/, $progInfo{'Program Genre'});
            $p->{'category'} = \@genres;
        }
        if ($progInfo{'Title Code'} ne '') {
            $p->{'episode number'} = ['EWTN:' . $progInfo{'Title Code'}];
        }

        $schedule{$progStartString} = $p;
    }

    return [
        {
            'id' => 'ewtn.optus_d2.xmltv.org'
            , 'name' => 'EWTN'
            , 'url' => [
                'http://www.ewtn.com/tv/'
            ]
            , 'schedule' => \%schedule
        }
    ];
}

1;

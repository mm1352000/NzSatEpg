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

package XmlTv::NzSatEpg::Channels::Daystar;

use DateTime;
use String::Similarity;

sub getChannelData {

    # We can get the Daystar schedule data in whatever time zone we like. GMT is a good convention.
    # Approximately 1 month of data is available, however there is not much meta information. About
    # all we can get are URLs for their descriptions of their shows (the descriptions on these
    # pages are non-specific and too long to integrate).
    print $::dbg "Daystar: Starting URL grab...\n";
    my $progInfo = {
    };
    my $response = $::wua->get('http://www.daystar.com/shows/');
    if ($response->is_error()) {
        print $::dbg __LINE__ . ': The request for the programme URLs failed. ' . $response->status_line() . "\n";
    }
    else {
        my $urlSection = $response->content;
        while ($urlSection =~ m/.*?<ul\sclass="\s*page-list\s*">(.*?)<\/ul>(.*)/s) {
            my $urlHtml = $1;
            $urlSection = $2;
            while ($urlHtml =~ m/.*?<a\s+href="([^"]*)">\s*(.*?)\s*<\/a>(.*)/s) {
                $urlHtml = $3;
                my ($url, $title, $host) = ($1, $2, undef);
                if ($title =~ m/^(.*)\s+with\s+(.*)$/) {
                    ($title, $host) = ($1, $2);
                }
                $progInfo->{$title}{'url'} = [$url];
                if (defined $host) {
                    $progInfo->{$title}{'host'} = [$host];
                }
            }
        }
    }

    # Grab the schedule data, one week at a time.
    print $::dbg "Daystar: Starting data grab...\n";
    my %schedule = ();
    my $runningDateTime = $::startDate->clone()->set_time_zone('UTC')->truncate(to => 'day');
    $runningDateTime->subtract(days => $runningDateTime->day_of_week % 7);
    my $targetTzDate = $runningDateTime->clone()->set_time_zone($::targetTimeZone);
    my %prevProg = (
        'title' => ''
        , 'start' => undef
    );
    while ($targetTzDate < $::endDate) {
        print $::dbg "Daystar:\tweek " . $runningDateTime->week_number() . " $runningDateTime...\n";
        $response = $::wua->get('http://www.daystar.com/legacy/index.php?option=com_daystar&view=schedule&layout=week&tmpl=component&format=raw&tz=25&week=' . $runningDateTime->week_number());
        if ($response->is_error()) {
            print $::dbg 'Daystar (' . __LINE__ . '): The request for the schedule HTML failed. ' . $response->status_line() . "\n";
            return undef;
        }
        if ($response->content !~ m/<table\s*class="scheduleweekview-body.*?<tr\s*class="row\d+"[^>]*>\s*(.+)\s*<\/tr>\s*<\/table>/s) {
            print $::dbg 'Daystar (' . __LINE__ . "): The schedule format has changed.\n";
            return undef;
        }
        my $weekSchedule = $1;

        my @timeSlots = split(/<\/tr>/, $weekSchedule);
        foreach my $dayIndex (0..6) {
            print $::dbg "Daystar:\tDay " . ($dayIndex + 1) . " of 7...\n";
            foreach my $slot (@timeSlots) {
                # Update the running time, being careful to properly manage midnight-crossings.
                $slot =~ m/scheduleweekview-body-time">\s*(.*?)\s*<\/th>/s;
                my ($progStartHours, $progStartMinutes) = XmlTv::NzSatEpg::toHoursAndMinutes($1);
                $runningDateTime->add(days => 1) if ($progStartHours < $runningDateTime->hour());
                $runningDateTime->set(hour => $progStartHours, minute => $progStartMinutes);

                # If a programme running on the current day starts/ends in this slot then we need
                # to process it.
                next if ($slot !~ m/scheduleweekview-body-day$dayIndex"[^>]*>\s*(.*?)\s*<\/td>/s);
                my $progTitle = $1;

                # Clean up the programme title. Note that some slots are empty; we assume that the
                # previous programme continues.
                $progTitle = ($progTitle =~ m/scheduleweekview-body-title">\s*(.*?)\s*<\/p>/s) ? $1 : $prevProg{'title'};

                # Aggregate programmes with the same name.
                next if ($progTitle eq $prevProg{'title'});

                # Attempt to find the URL of the Daystar description of programs for which there is no
                # exact match using a text similarity measurement.
                if (!exists $progInfo->{$progTitle}) {
                    $progInfo->{$progTitle} = undef;

                    my ($maxSim, $bestKey) = (0, '');
                    foreach my $key (keys %$progInfo) {
                        # Don't match on placeholder keys!
                        next if (!defined $progInfo->{$key});

                        my $sim = similarity($progTitle, $key);
                        if ($sim > $maxSim) {
                            $maxSim = $sim;
                            $bestKey = $key;
                        }
                        if (exists $progInfo->{$key}{'host'}) {
                            $sim = similarity($progTitle, $progInfo->{$key}{'host'}[0]);
                            if ($sim > $maxSim) {
                                $maxSim = $sim;
                                $bestKey = $key;
                            }
                        }
                    }

                    # 0.6 is the magic threshold number.
                    if ($maxSim > 0.6) {
                        #print $::dbg "Daystar: similarity match $maxSim, $progTitle  $bestKey\n";
                        $progInfo->{$progTitle} = $progInfo->{$bestKey};
                    }
                }

                my $currentDateTime = $runningDateTime->clone()->set_time_zone($::targetTimeZone)->strftime('%Y%m%d%H%M');
                if ($prevProg{'title'} ne ''
                    && $currentDateTime > $::startDate->strftime('%Y%m%d%H%M')
                    && $prevProg{'start'} < $::endDate->strftime('%Y%m%d%H%M')
                ) {
                    my $p = {
                        'title' => $prevProg{'title'}
                        , 'start' => $prevProg{'start'}
                        , 'end' => $currentDateTime
                    };
                    if (defined $progInfo->{$prevProg{'title'}}) {
                        foreach my $k (keys %{$progInfo->{$prevProg{'title'}}}) {
                            $p->{$k} = $progInfo->{$prevProg{'title'}}{$k};
                        }
                    }
                    $schedule{$prevProg{'start'}} = $p;
                }

                %prevProg = (
                    'title' => $progTitle
                    , 'start' => $currentDateTime
                );
            }
        }

        $targetTzDate->add(days => 7);
    }

    return [
        {
            'id' => 'daystar.optus_d2.xmltv.org'
            , 'name' => 'Daystar'
            , 'url' => [
                'http://www.daystar.com/'
            ]
            , 'schedule' => \%schedule
        }
    ];
}

1;
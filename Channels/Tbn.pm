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


# This script retrieves the EPG data for the TBN channels available from Optus D2 in Australia
# and New Zealand.
#
# We pull together the data from five sources:
# 1. The local Australasia TBN website, tbn.org.nz.
# 2. The global TBN website, tbn.org.
# 3. The Church Channel offical website, churchchannel.tv.
# 4. The JCTV official website, jctv.org.
# 5. The Smile Of A Child official website, smileofachildtv.org.
#
# The local TBN website has the definitive schedule, however it lacks programme descriptions. We
# retrieve the programme descriptions from the other sources where available. Note that the
# combined JCTV-SOAC channel shows JCTV programming from 6 PM to 6 AM Australia Eastern standard
# time and Smile Of A Child programming for the remainder of the time.

use strict;
use warnings;

package XmlTv::NzSatEpg::Channels::Tbn;

use DateTime;
use String::Similarity;

# Matches between global and local programme names that we aren't able to get automatically.
my %progMatches = (
    # TBN
    'pastor john hagee' => 'cornerstone'
    , 'pastor jentezen franklin' => 'kingdom connection'
    , 'dr. creflo dollar' => 'changing your world'
    , 'brian houston @ hillsong tv' => 'hillsong'
    , "hour of power - america's television church" => 'hour of power'
    , 'hazem' => 'reflections from the crystal cathedral'
    , 'best of praise' => 'praise the lord - live'
    , 'tbn highlights 2012' => 'best of tbn'
    , 'jordan rubin' => 'extraordinary health ÔÇô jordan rubin'
    # The Church Channel
    , 'aquilla nash' => 'prophetic whisper'
    , 'jentezen franklin' => 'kingdom connection'
    , 'ted shuttlesworth' => 'faith alive'
    , 'creflo dollar' => 'changing your world'
    , 'rabbi jonathan bernis' => 'jewish voice today'
    , 'pastor jerry barnard' => 'hope & healing'
    , 'reinhard bonnke' => 'full flame'
    , 'hazem farraj' => 'reflections from the crystal cathedral'
    , 'kenneth hagin, sr.' => 'rhema'
    # JCTV
    , 'liberty' => 'liberty program series'
    , 'music videos' => 'hardcore music blender'
    , 'praise and worship videos' => 'hardcore music blender'
    , 'reflections' => 'reflections from the crystal cathedral'
    # Smile Of A Child
    , 'torchlighters heroes of the faith: the samuel morris story' => 'the torchlighters'
    , 'veggietales: god loves you very much' => 'veggie tales'
    , 'ben hur' => 'ben hur movie- animated version'
);

# Cache for programme information, keyed by URL.
my $extendedInfo = {};

sub getChannelData {

    # Okay, so what we're going to do is run with the US schedules as bases. When we can identify
    # genuine variances between the local and US schedules we'll take the local data. Local
    # schedule data is in the AEST time zone (UTC+10); US data is in the PST time zone (UTC-8).
    my $schedule = [
        {
            'id' => 'tbn.optus_d2.xmltv.org'
            , 'name' => 'TBN International'
            , 'url' => [
                'http://www.tbn.org/'
                , 'http://www.tbn.org.au/'
            ]
            , 'schedule' => {}
        }
        , {
            'id' => 'church_channel.optus_d2.xmltv.org'
            , 'name' => 'The Church Channel'
            , 'url' => [
                'http://www.churchchannel.tv/'
            ]
            , 'schedule' => {}
        }
        , {
            'id' => 'jctv_soac.optus_d2.xmltv.org'
            , 'name' => 'JCTV-SOAC'
            , 'url' => [
                'http://www.jctv.org/'
                , 'http://www.smileofachildtv.org/'
            ]
            , 'schedule' => {}
        }
    ];

    my $usSchedule = [{}, {}, {}];

    # TBN international seems to be 10 hours behind TBN USA, and also occasionally shows
    # alternative programmes.
    $usSchedule->[0] = grabTbnSchedule(10, 'TBN', 'http://www.tbn.org');
    aggregateProgrammes($usSchedule->[0]);

    # As far as I'm aware, the other channels show the exact same programmes shown in the US with
    # no offset.
    $usSchedule->[1] = grabTbnSchedule(0, 'The Church Channel', 'http://www.churchchannel.tv');
    aggregateProgrammes($usSchedule->[1]);
    $usSchedule->[2] = grabTbnSchedule(0, 'Smile Of A Child', 'http://www.smileofachildtv.org');
    grabJctvSchedule($usSchedule->[2]);
    aggregateProgrammes($usSchedule->[2]);

    # Cross-check with the tbn.org.au schedule.
    print $::dbg "TBN: Starting local data grab...\n";
    my $localSchedule = [{}, {}, {}];
    my $currentAestDate = $::startDate->clone()->set_time_zone('Australia/Sydney')->truncate(to => 'day');
    my $targetTzDate = $currentAestDate->clone()->set_time_zone($::targetTimeZone);
    my $prevProgs = [{'title' => '', 'start' => ''}, {'title' => '', 'start' => ''}, {'title' => '', 'start' => ''}];
    while ($targetTzDate < $::endDate) {
        # Grab the TBN AU data for the day.
        print $::dbg "TBN:\tday $targetTzDate...\n";
        my $response = $::wua->get('http://tvguide.tbn.org.au/day.cfm?dst=' . $currentAestDate->is_dst() . '&offset=1000&date=' . $currentAestDate->strftime('%d%m%Y'));
        if ($response->is_error()) {
            print $::dbg 'TBN (' . __LINE__ . '): The request for the tbn.org.au schedule HTML failed. ' . $response->status_line() . "\n";
            return undef;
        }

        # Cut to the relevant content.
        if ($response->content =~ m/<div class="alert info">Sorry - no programme information found on this day.<\/div>/) {
            last;
        }
        elsif ($response->content !~ m/programmes_heading">12:00\sAM.*?<\/th>(.*)/s) {
            print $::dbg 'TBN (' . __LINE__ . "): The tbn.org.au schedule format has changed.\n";
            return undef;
        }
        my $html = $1;

        # For each half hour slot in the day...
        for my $halfHourSlot (0..47) {
            my $currDateTime = $targetTzDate->strftime('%Y%m%d%H%M');

            # For each channel...
            for my $channelIndex (0..2) {
                if ($html !~ m/.*?<td[^>]*>\s*(.*?)\s*<\/td>(.*)/s) {
                    print $::dbg 'TBN (' . __LINE__ . "): The tbn.org.au schedule content format has changed.\n";
                    return undef;
                }
                my $progTitle = $1;
                $html = $2;

                if ($progTitle ne '&nbsp;' || (
                    $channelIndex == 2 && ($halfHourSlot == 12 || $halfHourSlot == 36)
                )) {
                    # Special case: JCTV/SOAC programming changeovers.
                    # There seems to be a general bug in the tbn.org.au guide data injest.
                    # Sometimes there are large blocks of time that are obviously missing data.
                    # There is very little we can do about that except to go with the US data. For
                    # JCTV-SOAC the first programme in a programming block may be blank (ie. it
                    # indicates an extension of the previous programme... but that can't happen
                    # since it is a channel changeover). This seems to occur when the changeover
                    # doesn't coincide with the start of a programme. For example, JCTV runs music
                    # videos from 5:30pm - 6:30pm AEST; local channel switches to JCTV at 6pm AEST;
                    # the schedule for 6pm - 6:30pm will be blank.
                    my $prevProgStart = $prevProgs->[$channelIndex]{'start'};
                    if ($prevProgs->[$channelIndex]{'title'} ne ''
                        && $progTitle ne $prevProgs->[$channelIndex]{'title'}
                        && $currDateTime > $::startDate->strftime('%Y%m%d%H%M')
                        && $prevProgStart < $::endDate->strftime('%Y%m%d%H%M')
                    ) {
                        $localSchedule->[$channelIndex]{$prevProgStart} = {
                            'start' => $prevProgStart
                            , 'end' => $currDateTime
                            , 'title' => $prevProgs->[$channelIndex]{'title'}
                        };
                    }

                    $prevProgs->[$channelIndex]{'title'} = ($progTitle eq '&nbsp;') ? '' : $progTitle;
                    $prevProgs->[$channelIndex]{'start'} = $currDateTime;
                }
            }

            $targetTzDate->add(minutes => 30);
        }

        $currentAestDate->add(days => 1);
    }

    print $::dbg "TBN: Starting data crosscheck...\n";
    my $finalDateTime = $targetTzDate->strftime('%Y%m%d%H%M');
    for my $channelIndex (0..2) {
        # Last programme for each channel...
        my $prevProgStart = $prevProgs->[$channelIndex]{'start'};
        if ($prevProgs->[$channelIndex]{'title'} ne ''
            && $finalDateTime > $::startDate->strftime('%Y%m%d%H%M')
            && $prevProgStart < $::endDate->strftime('%Y%m%d%H%M')
        ) {
            $localSchedule->[$channelIndex]{$prevProgStart} = {
                'start' => $prevProgStart
                , 'end' => $finalDateTime
                , 'title' => $prevProgs->[$channelIndex]{'title'}
            };
        }

        my %tempTimes = ();
        my @usTimes = sort keys %{$usSchedule->[$channelIndex]};
        my @localTimes = sort keys %{$localSchedule->[$channelIndex]};
        map { $tempTimes{$_} = 1 } @usTimes;
        map { $tempTimes{$_} = 1 } @localTimes;
        my @times = sort keys %tempTimes;
        my $nextTime = undef;
        foreach my $time (@times) {
            next if (defined $nextTime && $time < $nextTime);

            # Match/select programmes.
            if (!exists $localSchedule->[$channelIndex]{$time}) {
                if ($time > $localTimes[0] && $time < $localTimes[$#localTimes]) {
                    #print $::dbg "TBN: Exclusive US programme $time.." . $usSchedule->[$channelIndex]{$time}{'end'} . " '" . $usSchedule->[$channelIndex]{$time}{'title'} . "'.\n";
                }
                $schedule->[$channelIndex]{'schedule'}{$time} = $usSchedule->[$channelIndex]{$time};
            }
            elsif (!exists $usSchedule->[$channelIndex]{$time}) {
                if ($time > $usTimes[0] && $time < $usTimes[$#usTimes]) {
                    #print $::dbg "TBN: Exclusive local programme $time.." . $localSchedule->[$channelIndex]{$time}{'end'} . " '" . $localSchedule->[$channelIndex]{$time}{'title'} . "'.\n";
                }
                $schedule->[$channelIndex]{'schedule'}{$time} = $localSchedule->[$channelIndex]{$time};
            }
            else {
                if (matchProgrammes($usSchedule->[$channelIndex]{$time}, $localSchedule->[$channelIndex]{$time}{'title'})) {
                    $schedule->[$channelIndex]{'schedule'}{$time} = $usSchedule->[$channelIndex]{$time};
                    if ($usSchedule->[$channelIndex]{$time}{'end'} > $localSchedule->[$channelIndex]{$time}{'end'}) {
                        print $::dbg "TBN: Shorten US programme '" . $localSchedule->[$channelIndex]{$time}{'title'} . "' starting $time from " . $usSchedule->[$channelIndex]{$time}{'end'} . ' to ' . $localSchedule->[$channelIndex]{$time}{'end'} . ".\n";
                        $schedule->[$channelIndex]{'schedule'}{$time}{'end'} = $localSchedule->[$channelIndex]{$time}{'end'};
                    }
                }
                else {
                    print $::dbg "TBN: Exclusive local programme $time.." . $localSchedule->[$channelIndex]{$time}{'end'} . " '" . $localSchedule->[$channelIndex]{$time}{'title'} . "'.\n";
                    print $::dbg "TBN:     US programme $time.." . $usSchedule->[$channelIndex]{$time}{'end'} . " '" . $usSchedule->[$channelIndex]{$time}{'title'} . "'.\n";
                    $schedule->[$channelIndex]{'schedule'}{$time} = $localSchedule->[$channelIndex]{$time};
                }
            }

            # Enrich the programme data.
            if (exists $schedule->[$channelIndex]{'schedule'}{$time}{'url'} && defined $schedule->[$channelIndex]{'schedule'}{$time}{'url'}[0]) {
                my $url = $schedule->[$channelIndex]{'schedule'}{$time}{'url'}[0];
                if (exists $extendedInfo->{$url}) {
                    foreach my $i (keys %{$extendedInfo->{$url}}) {
                        $schedule->[$channelIndex]{'schedule'}{$time}{$i} = $extendedInfo->{$url}{$i};
                    }
                }
            }

            $nextTime = $schedule->[$channelIndex]{'schedule'}{$time}{'end'};
        }
    }

    return $schedule;
}

sub matchProgrammes {

    my ($usProg, $localProgTitle) = @_;

    # Attempt to match the US and local programmes. This is tricky because the local guide data
    # uses official programme titles whereas the US guide data tends to use producer/pastor names.
    my $match = 0;
    my $lcLocalProgTitle = lc($localProgTitle);
    my $lcUsProgTitle = lc($usProg->{'title'});
    if (!exists $progMatches{$lcUsProgTitle}) {
        my $sim = similarity($lcLocalProgTitle, $lcUsProgTitle);
        if ($sim >= 0.5) {
            $progMatches{$lcUsProgTitle} = $lcLocalProgTitle;
        }
        elsif (exists $usProg->{'url'} && exists $extendedInfo->{$usProg->{'url'}[0]}) {
            my $info = $extendedInfo->{$usProg->{'url'}[0]};
            if (exists $info->{'host'}) {
                $sim = similarity($lcLocalProgTitle, lc($info->{'host'}[0]));
                if ($sim >= 0.5) {
                    $progMatches{$lcUsProgTitle} = $lcLocalProgTitle;
                }
            }
            if (!exists $progMatches{$lcUsProgTitle} && defined $info->{'title'}) {
                $sim = similarity($lcLocalProgTitle, lc($info->{'title'}));
                if ($sim >= 0.5) {
                    $progMatches{$lcUsProgTitle} = $lcLocalProgTitle;
                }
            }
        }
    }
    if (exists $progMatches{$lcUsProgTitle}) {
        return 1;
    }

    return 0;
}

sub aggregateProgrammes {

    my ($schedule) = @_;
    my $prevStartTime = 0;
    foreach my $startTime (sort keys %{$schedule}) {
        if ($prevStartTime != 0 && $schedule->{$prevStartTime}{'title'} eq $schedule->{$startTime}{'title'}) {
            $schedule->{$prevStartTime}{'end'} = $schedule->{$startTime}{'end'};
            delete $schedule->{$startTime};
            next;
        }
        $prevStartTime = $startTime;
    }
}

sub grabTbnSchedule {

    my ($offset, $channelName, $channelUrlStub) = @_;

    # Get the raw HTML containing the schedule for the week.
    print $::dbg "TBN: Starting data grab for $channelName...\n";
    my $schedule = {};
    my $currentPstDate = $::startDate->clone()->add(hours => -$offset)->set_time_zone('America/Los_Angeles')->truncate(to => 'day');
    my $daysGrabbed = 0;
    while ($::daysToGrab - $daysGrabbed > 0) {
        my $response = $::wua->get("$channelUrlStub/watch/schedule_weekview.php?timezone=p&view=7&date=" . $currentPstDate->strftime('%Y%m%d'));
        if ($response->is_error()) {
            $channelUrlStub =~ s/http:\/\/www\.//;
            print $::dbg 'TBN (' . __LINE__ . '): The request for the $channelUrlStub schedule HTML failed. ' . $response->status_line() . "\n";
            return undef;
        }
        my $html = $response->content;

        # Separate the schedule from the programme descriptions.
        $html =~ m/class="schedulehead">.+?<\/th>\s*<\/tr>\s*<tr>(.+?)<!--\s*(brief_description_array\[.+)/s;
        my ($scheduleHtml, $descriptionHtml) = ($1, $2);

        # Process the descriptions first.
        print $::dbg "TBN: Processing programme descriptions.\n";
        my %descriptions = ();
        while ($descriptionHtml =~ m/brief_description_array\["(\d+)"\]\s*=\s*"\s*(<b.*?<\/b>\s*<br>)?(<span[^>]*>)?([^"]*?)\s*(<\/span>)?\s*"\s*;(.*)/s) {
            my ($descId, $desc) = ($1, $4);
            $descriptionHtml = $6;
            $descriptions{$descId} = $desc;
        }

        # Now process the schedule.
        print $::dbg "TBN: Processing the schedule.\n";
        my @dayProcessingProgress = (0, 0, 0, 0, 0, 0, 0);
        foreach my $halfHourSlot (split(/<tr>/, $scheduleHtml)) {
            # Separate the start time from the details of the programmes that run in that slot (over
            # the course of the week).
            $halfHourSlot =~ m/.+?<b>(.+?)<\/b>.+?<\/td>(.*)/;
            my ($progStartHours, $progStartMinutes) = XmlTv::NzSatEpg::toHoursAndMinutes($1);
            $halfHourSlot = $2;
            print $::dbg "TBN:\t$progStartHours:$progStartMinutes...\n";

            # Check the details for each of the programmes in each slot.
            my $currentDay = 0;
            while (defined $halfHourSlot && $halfHourSlot =~ m/\s*<td([^>]*)>\s*(.*?)\s*<\/td>(.*)/s) {
                my ($style, $progTitle, $progLength, $progCategory, $commonDays, $descId, $progUrl) = ($1, $2 || '', 1, undef, 1, -1, '');
                $halfHourSlot = $3;

                # Find the first day that this programme runs on.
                while ($currentDay < 7) {
                    ($dayProcessingProgress[$currentDay] <= (($progStartHours * 2) + ($progStartMinutes / 30))) ? last : $currentDay++;
                }

                # Programmes don't always have all details available so tread carefully here.
                if ($style =~ m/rowspan=(\d+)\s+colspan=(\d+)/s) {
                    ($progLength, $commonDays) = ($1, $2);
                    if ($progTitle =~ m/set_and_show\(this,\s'(\d+)'.+?href="\s*([^"]*)\s*">\s*(.*?)\s*<\/a>/s) {
                        ($descId, $progUrl, $progTitle) = ($1, $2, $3 || '');
                        if (defined $progUrl && substr($progUrl, 0, 1) eq '/') {
                            $progUrl = $channelUrlStub . $progUrl;
                        }
                    }
                }
                if ($style =~ m/class="\s*(.*?)\s*"/) {
                    if ($1 eq 'movie_show') {
                        $progCategory = 'movie';
                    }
                    elsif ($1 eq 'special_show') {
                        $progCategory = 'special';
                    }
                    elsif ($1 eq 'featured_show') {
                        $progCategory = 'feature';
                    }
                }

                my $progStartDateTime = $currentPstDate->clone()->set_time_zone($::targetTimeZone);
                $progStartDateTime->add(days => $currentDay, hours => $progStartHours + $offset, minutes => $progStartMinutes);
                my $progEndDateTime = $progStartDateTime->clone()->add(minutes => ($progLength * 30));

                # Ignore the Smile Of A Child programmes outside 6 AM to 6 PM AEST - they're JCTV
                # programmes in the local schedule so any attempts at matching just won't work.
                if ($channelName eq 'Smile Of A Child') {
                    my $aestStartDateTime = $progStartDateTime->clone()->set_time_zone('Australia/Sydney');
                    my $aestEndDateTime = $progEndDateTime->clone()->set_time_zone('Australia/Sydney');
                    my $startTimeIsSoac = 0;
                    my $endTimeIsSoac = 0;
                    if ($aestStartDateTime->hour() >= 6 && $aestStartDateTime->hour() < 18) {
                        $startTimeIsSoac = 1;
                    }
                    if (($aestEndDateTime->hour() == 6 && $aestEndDateTime->minute() > 0)
                        || ($aestEndDateTime->hour() > 6 && $aestEndDateTime->hour() < 18)
                        || ($aestEndDateTime->hour() == 18 && $aestEndDateTime->minute() == 0)
                    ) {
                        $endTimeIsSoac = 1;
                    }
                    if (!$startTimeIsSoac && !$endTimeIsSoac) {
                        # This programme is of no interest to us... but we still have to update our
                        # processing position.
                        for (1..$commonDays) {
                            $dayProcessingProgress[$currentDay] += $progLength;
                            $currentDay++;
                        }
                        next;
                    }

                    # Truncate programmes that span the changeover times.
                    if (!$startTimeIsSoac) {
                        $progStartDateTime = $aestStartDateTime->set(hour => 6, minute => 0)->set_time_zone($::targetTimeZone);
                    }
                    if (!$endTimeIsSoac) {
                        $progEndDateTime = $aestEndDateTime->set(hour => 18, minute => 0)->set_time_zone($::targetTimeZone);
                    }
                }

                # If we have a URL, look up the extended info.
                if ($progUrl ne '' && !exists $extendedInfo->{$progUrl}) {
                    $response = $::wua->get($progUrl);
                    if ($response->is_success()) {
                        $extendedInfo->{$progUrl} = {
                            'url' => [$progUrl]
                        };
                        if ($response->content =~ m/<span\sclass="programhost">\s*([^<]+)\s*<\/span>/s) {
                            $extendedInfo->{$progUrl}{'host'} = [$1];
                        }
                        if ($response->content =~ m/<span\sclass="programname">\s*(.*?)\s*<\/span>/s) {
                            $extendedInfo->{$progUrl}{'title'} = $1;
                        }
                        if ($response->content =~ m/You\scan\svisit\sthe\swebsite\sat.*?<a\shref="(.*?)"/s) {
                            $extendedInfo->{$progUrl}{'url'} = [$1, $progUrl];
                        }
                    }
                }

                # For each day that this programme shows on...
                for (1..$commonDays) {
                    my $progStartString = $progStartDateTime->strftime('%Y%m%d%H%M');
                    if ($progEndDateTime > $::startDate
                        && $progStartDateTime < $::endDate
                        && $progTitle ne 'This show has been removed from our list of programs.'
                        && $progTitle ne 'TBA'
                    ) {
                        $schedule->{$progStartString} = {
                            'start' => $progStartString
                            , 'end' => $progEndDateTime->strftime('%Y%m%d%H%M')
                            , 'title' => $progTitle
                            , 'description' => $descriptions{$descId}
                        };
                        if (defined $progUrl && $progUrl ne '') {
                            $schedule->{$progStartString}{'url'} = [$progUrl];
                        }
                        if (defined $progCategory) {
                            $schedule->{$progStartString}{'category'} = [$progCategory];
                        }
                    }

                    $progStartDateTime->add(days => 1);
                    $progEndDateTime->add(days => 1);

                    # Keep track of processing progress.
                    $dayProcessingProgress[$currentDay] += $progLength;
                    $currentDay++;
                }
            }
        }

        $currentPstDate->add(days => 7);
        $daysGrabbed += 7;
    }

    return $schedule;
}

sub grabJctvSchedule {

    my ($schedule) = @_;

    print $::dbg "TBN: Starting data grab for JCTV...\n";

    # Schedule is provided by day of the week, but this seems to be wrapped-around rather than
    # constant. The trickiest part is calculating how the days of the week line up with dates/times
    # in the target timezone. We'll assemble a schedule one day at a time.
    my $referencePstDate = DateTime->today(time_zone => 'America/Los_Angeles');
    my $referenceDayOfWeekIndex = $referencePstDate->day_of_week % 7;
    my %prevProg = (
        'title' => ''
        , 'startDay' => 0
        , 'startTime' => ''
        , 'length' => 0
        , 'url' => ''
    );
    for my $processingDayIndex (0..6) {
        # Get the raw HTML containing the schedule for this day.
        print $::dbg "TBN:\tday " . ($processingDayIndex + 1) . "...\n";
        my $websiteDayIndex = ($referenceDayOfWeekIndex + $processingDayIndex) % 7;
        my $response = $::wua->get("http://www.jctv.org/includes/flashschedule.php?day=$websiteDayIndex");
        if ($response->is_error()) {
            print $::dbg 'TBN (' . __LINE__ . '): The request for the jctv.org schedule HTML failed. ' . $response->status_line() . "\n";
            return;
        }
        my $html = $response->content;

        # A little clean-up...
        $html =~ s/&?plist\d=//g;
        $html =~ s/<br>&progend=\d//;

        # Throw in a dummy programme on the last day to save having to do special stuff to catch
        # the [real] last programme of the week.
        if ($processingDayIndex == 6) {
            $html .= "<br>12:00 AM_popup('watchlive'_\">Dummy</a>";
        }

        # Process the schedule, aggregating time-adjacent programmes with the same name.
        foreach my $progHtml (split(/<br>/, $html)) {
            # Separate the programme details.
            $progHtml =~ m/(<b><font[^>]*>)?\s*(\d+:\d+\s*(A|P)M).+popup\('([^']+)'.+">(.+?)<\//;
            my ($rawStartTime, $progUrl, $progTitle) = ($2, "http://www.jctv.org$4", $5);

            # Grab the programme description if we don't have it already. Note that it is not
            # possible to get the description for the live programme.
            if ($progUrl !~ m/watchlive/ && !exists $extendedInfo->{$progUrl}) {
                $response = $::wua->get($progUrl);
                if ($response->is_success()) {
                    $extendedInfo->{$progUrl} = {
                        'url' => [$progUrl]
                    };
                    # Cut to the most important part of the HTML.
                    $response->content =~ m/<b>\Q$progTitle\E<\/b>\s*(<br>\s*<br>)?\s*(.*?)\s*<br>\s*<br>\s*<table/s;
                    $extendedInfo->{$progUrl}{'description'} = $2;

                    # Pull out the host's name if it is mentioned.
                    $extendedInfo->{$progUrl}{'description'} =~ m/\s*(<b>\s*Hosted.+?<\/b>\s*(.+?)\s*<br>\s*<br>\s*)?\s*(.*?)\s*$/s;
                    if (defined $2) {
                        $extendedInfo->{$progUrl}{'host'} = [$2];
                        $extendedInfo->{$progUrl}{'description'} = $3;
                    }

                    # Pull out the URL for the programme's real website if it is mentioned.
                    if ($extendedInfo->{$progUrl}{'description'} =~ m/\s*(.*?)\s*<br><br>\s*You can visit.+href="([^"]+)".*/s) {
                        $extendedInfo->{$progUrl}{'description'} = $1;
                        $extendedInfo->{$progUrl}{'url'} = [$2, $progUrl];
                    }
                }
            }

            # Aggregate adjacent programmes with the same name.
            if ($progTitle eq $prevProg{'title'}) {
                $prevProg{'length'} += 30;
                next;
            }

            # If we get to here then one programme is finishing and another is starting. Handle the
            # programme that is finishing.
            if ($prevProg{'title'} ne '') {
                my ($progStartHours, $progStartMinutes) = XmlTv::NzSatEpg::toHoursAndMinutes($prevProg{'startTime'});
                my $progStartDateTime = $referencePstDate->clone()->set_time_zone('Australia/Sydney');
                $progStartDateTime->add(days => $prevProg{'startDay'}, hours => $progStartHours, minutes => $progStartMinutes);
                my $progEndDateTime = $progStartDateTime->clone()->add(minutes => $prevProg{'length'});

                # Ignore the programmes outside 6 PM to 6 PM AEST - they're Smile Of A Child
                # programmes in the local schedule so any attempts at matching just won't work.
                my $startTimeIsJctv = 0;
                my $endTimeIsJctv = 0;
                if ($progStartDateTime->hour() < 6 || $progStartDateTime->hour() >= 18) {
                    $startTimeIsJctv = 1;
                }
                if (($progEndDateTime->hour() == 6 && $progEndDateTime->minute() == 0)
                    || $progEndDateTime->hour() < 6
                    || $progEndDateTime->hour() > 18
                    || ($progEndDateTime->hour() == 18 && $progEndDateTime->minute() > 0)
                ) {
                    $endTimeIsJctv = 1;
                }
                if ($startTimeIsJctv || $endTimeIsJctv) {
                    # Truncate programmes that span the changeover times.
                    if (!$startTimeIsJctv) {
                        $progStartDateTime->set(hour => 18, minute => 0);
                    }
                    if (!$endTimeIsJctv) {
                        $progEndDateTime->set(hour => 6, minute => 0);
                    }

                    my $progStartString = $progStartDateTime->set_time_zone($::targetTimeZone)->strftime('%Y%m%d%H%M');
                    my $progEndString = $progEndDateTime->set_time_zone($::targetTimeZone)->strftime('%Y%m%d%H%M');

                    if ($progEndString > $::startDate->strftime('%Y%m%d%H%M')
                        && $progStartString < $::endDate->strftime('%Y%m%d%H%M')
                        && $prevProg{'title'} ne 'This show has been removed from our list of programs.'
                        && $prevProg{'title'} ne 'TBA'
                    ) {
                        $schedule->{$progStartString} = {
                            'start' => $progStartString
                            , 'end' => $progEndString
                            , 'title' => $prevProg{'title'}
                            , 'url' => [$prevProg{'url'}]
                        };
                    }
                }
            }

            # Now deal with the programme that is starting.
            %prevProg = (
                'title' => $progTitle
                , 'startDay' => $processingDayIndex
                , 'startTime' => $rawStartTime
                , 'length' => 30
                , 'url' => $progUrl
            );
        }
    }
}

1;
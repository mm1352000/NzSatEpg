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

package XmlTv::NzSatEpg::Channels::HopeChannel;

use DateTime;
use Spreadsheet::ParseExcel;

sub getChannelData {

    print $::dbg "Hope: Starting data grab...\n";

    my $response = $::wua->get('http://www.hopetv.org/watch/program-guide/');
    if ($response->is_error()) {
        print $::dbg 'Hope (' . __LINE__ . '): The request for the schedule page HTML failed. ' . $response->status_line() . "\n";
        return undef;
    }
    if ($response->content !~ m/.*\s+href="([^"]+hci.xls)".*/s) {
        print $::dbg 'Hope (' . __LINE__ . "): Failed to find the schedule XLS link.\n";
        return undef;
    }
    $response = $::wua->get("http://www2.hopetv.org/$1");
    if ($response->is_error()) {
        print $::dbg 'Hope (' . __LINE__ . "): Error downloading the schedule XLS from \"$1\". " . $response->status_line() . "\n";
        return undef;
    }
    if (!open(TEMP, ">$::tempPath\\Hope.xls")) {
        print $::dbg 'Hope (' . __LINE__ . "): Failed to save the schedule XLS to disk.\n";
        return undef;
    }
    binmode(TEMP);
    print TEMP $response->content;
    close(TEMP);

    # This schedule contains UTC times which are easy to use. The schedule is organised onto
    # multiple sheets. The first sheet contains a general schedule for the quarter; the other
    # sheets contain specific schedules by week.
    my %schedule = ();
    my $referenceDateTime = undef;
    my $parser = Spreadsheet::ParseExcel->new();
    my $xls = $parser->Parse("$::tempPath\\Hope.xls");
    my $lastSheetIndex = $xls->worksheet_count() - 1;
    my %prevProg = (
        'title' => ''
        , 'length' => 0
    );
    foreach my $sheetIndex (1..$lastSheetIndex) {
        print $::dbg "Hope:\tsheet $sheetIndex...\n";
        my $sheet = $xls->worksheet($sheetIndex);

        # Get the reference date from the sub-title on the first sheet.
        if (!defined $referenceDateTime) {
            my $rawTitle = $sheet->get_cell(3, 2)->value();
            if ($rawTitle =~ m/^\s*([^\s]+)\s+(\d+).*$/) {
                $referenceDateTime = DateTime->today(time_zone => 'UTC')->set(day => $2, month => $::monthMap{$1}, hour => 0, minute => 0);
                # Handle the case where the first month in the schedule is in a different year to
                # the current date. For example, reading the schedule for December in January or
                # later.
                if (($referenceDateTime - DateTime->today())->months() > 6) {
                    $referenceDateTime->add(years => -1);
                }
            }
            else {
                print $::dbg 'Hope (' . __LINE__ . "): The sheet schedule date could not be parsed.\n";
                return undef;
            }
        }

        # Process the schedule one day at a time. We record the details for one programme as the
        # next programme starts.
        foreach my $colIndex (2..8) {
            print $::dbg "Hope:\tday " . ($colIndex - 1) . " of 7...\n";
            foreach my $rowIndex (5..52) {
                my $cell = $sheet->get_cell($rowIndex, $colIndex);
                my $progTitle = $cell->value();

                # If the cell is merged then we need to find the contents of the merged area that
                # it is a part of.
                if ($cell->is_merged() && $progTitle eq '') {
                    my $mergedAreas = $sheet->get_merged_areas();
                    foreach my $a (@{$mergedAreas}) {
                        if (
                            $rowIndex >= ${$a}[0]
                            && $colIndex >= ${$a}[1]
                            && $rowIndex <= ${$a}[2]
                            && $colIndex <= ${$a}[3]
                        ) {
                            $progTitle = $sheet->get_cell(${$a}[0], ${$a}[1])->value();
                        }
                    }
                }

                # Aggregate programmes with the same name.
                if ($progTitle eq $prevProg{'title'}) {
                    $prevProg{'length'}++;
                    next;
                }

                # If we get to here then one program is finishing and another is starting. First print the
                # details of the program that is finishing.
                my $progStartDateTime = $referenceDateTime->clone()->set_time_zone($::targetTimeZone);
                my $progEndDateTime = $progStartDateTime->clone()->add(minutes => $prevProg{'length'} * 30);
                $referenceDateTime->add(minutes => $prevProg{'length'} * 30);
                if ($prevProg{'title'} ne '' && $progEndDateTime > $::startDate && $progStartDateTime < $::endDate) {
                    $schedule{$progStartDateTime->strftime("%Y%m%d%H%M")} = {
                        'title' => $prevProg{'title'}
                        , 'start' => $progStartDateTime->strftime("%Y%m%d%H%M")
                        , 'end' => $progEndDateTime->strftime("%Y%m%d%H%M")
                    };
                }

                # Now deal with the programme that is starting.
                %prevProg = (
                    'title' => $progTitle
                    , 'length' => 1
                );
            }
        }
    }

    return [
        {
            'id' => 'hope_channel.optus_d2.xmltv.org'
            , 'name' => 'Hope Channel'
            , 'url' => [
                'http://www.hopetv.org/'
            ]
            , 'schedule' => \%schedule
        }
    ];
}

1;
let
    Source = Csv.Document(
        File.Contents("C:\Users\andre\Downloads\main_vscode\portfolio\projects\pbi\project_timelines.csv"),
        [Delimiter=",", Columns=11, Encoding=1252, QuoteStyle=QuoteStyle.None]
    ),
    #"Promoted Headers" = Table.PromoteHeaders(Source, [PromoteAllScalars=true]),
    #"Changed Type" = Table.TransformColumnTypes(#"Promoted Headers", {
        {"ProjectID",              type text},
        {"ProjectName",            type text},
        {"ProjectStartDate",       type date},
        {"MilestoneHeading",       type text},
        {"MilestoneID",            type text},
        {"MilestoneName",          type text},
        {"DependsOnMilestoneID",   type text},
        {"PlannedDuration_days",   Int64.Type},
        {"ActualDuration_days",    type nullable number},
        {"ProgressPct",            Int64.Type},
        {"Status",                 type text}
    }),

    // Composite key: ProjectID & "|" & MilestoneID — avoids collisions when IDs restart per project
    RowList   = Table.ToRecords(#"Changed Type"),
    RowLookup = Record.FromList(
        RowList,
        List.Transform(RowList, each _[ProjectID] & "|" & _[MilestoneID])
    ),

    // Recursive: planned start = ProjectStartDate for first milestone (no dependency),
    //            or dependency's PlannedStartDate + PlannedDuration for all others
    GetPlannedStart = (pid as text, id as text) as date =>
        let
            key = pid & "|" & id,
            row = Record.Field(RowLookup, key),
            dep = row[DependsOnMilestoneID]
        in
            if dep = null or dep = ""
            then row[ProjectStartDate]
            else
                let
                    depRow = Record.Field(RowLookup, pid & "|" & dep)
                in
                    Date.AddDays(@GetPlannedStart(pid, dep), depRow[PlannedDuration_days]),

    // Recursive: actual start propagates from actual completion of predecessor;
    //            null if any predecessor hasn't finished yet
    GetActualStart = (pid as text, id as text) as nullable date =>
        let
            key = pid & "|" & id,
            row = Record.Field(RowLookup, key),
            dep = row[DependsOnMilestoneID]
        in
            if dep = null or dep = ""
            then row[ProjectStartDate]
            else
                let
                    depRow       = Record.Field(RowLookup, pid & "|" & dep),
                    depActualDur = depRow[ActualDuration_days]
                in
                    if depActualDur = null
                    then null
                    else
                        let depActualStart = @GetActualStart(pid, dep)
                        in  if depActualStart = null
                            then null
                            else Date.AddDays(depActualStart, depActualDur),

    // Materialise planned and actual dates
    WithPlannedStart = Table.AddColumn(#"Changed Type", "PlannedStartDate",
        each GetPlannedStart([ProjectID], [MilestoneID]), type date),
    WithPlannedEnd   = Table.AddColumn(WithPlannedStart, "PlannedEndDate",
        each Date.AddDays([PlannedStartDate], [PlannedDuration_days]), type date),
    WithActualStart  = Table.AddColumn(WithPlannedEnd, "ActualStartDate",
        each GetActualStart([ProjectID], [MilestoneID]), type nullable date),
    WithActualEnd    = Table.AddColumn(WithActualStart, "ActualEndDate",
        each if [ActualStartDate] = null or [ActualDuration_days] = null
             then null
             else Date.AddDays([ActualStartDate], [ActualDuration_days]),
        type nullable date),

    // ── Critical Path (backward pass) ────────────────────────────────────────
    // Build a row list that includes the computed PlannedStartDate/PlannedEndDate
    RowListDated = Table.ToRecords(WithPlannedEnd),
    ProjectIDs   = List.Distinct(List.Transform(RowListDated, each _[ProjectID])),

    // Latest-finish date per project = max PlannedEndDate across all its milestones
    ProjectEndLookup = Record.FromList(
        List.Transform(ProjectIDs, each
            List.Max(List.Transform(
                List.Select(RowListDated, (r) => r[ProjectID] = _),
                (r) => r[PlannedEndDate]
            ))
        ),
        ProjectIDs
    ),

    // Recursive backward pass: LF(task) = min(LS of direct successors), or project end if none
    GetLF = (pid as text, id as text) as date =>
        let
            successors = List.Select(RowListDated,
                each _[ProjectID] = pid
                    and _[DependsOnMilestoneID] <> null
                    and _[DependsOnMilestoneID] <> ""
                    and _[DependsOnMilestoneID] = id
            ),
            projEnd = Record.Field(ProjectEndLookup, pid)
        in
            if List.IsEmpty(successors) then projEnd
            else List.Min(List.Transform(successors,
                each Date.AddDays(@GetLF(pid, _[MilestoneID]), -_[PlannedDuration_days])
            )),

    WithLF       = Table.AddColumn(WithActualEnd,  "LatestFinish",
        each GetLF([ProjectID], [MilestoneID]), type date),
    WithFloat    = Table.AddColumn(WithLF,          "TotalFloat_days",
        each Duration.Days([LatestFinish] - [PlannedEndDate]), Int64.Type),
    WithCritical = Table.AddColumn(WithFloat,       "IsCritical",
        each [TotalFloat_days] = 0, type logical),

    // ── HeadingNumber / MilestoneNumber ──────────────────────────────────────
    HeadingMinDates = Table.Group(WithCritical, {"ProjectID", "MilestoneHeading"},
        {{"HeadingMinDate", each List.Min([PlannedStartDate]), type nullable date}}),
    HeadingsSorted  = Table.Sort(HeadingMinDates, {
        {"ProjectID", Order.Ascending}, {"HeadingMinDate", Order.Ascending}, {"MilestoneHeading", Order.Ascending}
    }),
    HeadingGrouped  = Table.Group(HeadingsSorted, {"ProjectID"}, {{"Rows", each _, type table}}),
    HeadingNumbered = Table.TransformColumns(HeadingGrouped, {
        {"Rows", each Table.AddIndexColumn(_, "HeadingNumber", 1, 1, Int64.Type), type table}
    }),
    HeadingFlat     = Table.Combine(HeadingNumbered[Rows]),
    Joined          = Table.NestedJoin(WithCritical, {"ProjectID", "MilestoneHeading"},
                        HeadingFlat, {"ProjectID", "MilestoneHeading"}, "_hd", JoinKind.LeftOuter),
    WithHeading     = Table.ExpandTableColumn(Joined, "_hd",
                        {"HeadingNumber", "HeadingMinDate"}, {"HeadingNumber", "HeadingMinDate"}),
    MilestoneSorted  = Table.Sort(WithHeading, {
        {"ProjectID", Order.Ascending}, {"HeadingNumber", Order.Ascending},
        {"PlannedStartDate", Order.Ascending}, {"MilestoneID", Order.Ascending},
        {"MilestoneName", Order.Ascending}
    }),
    MilestoneGrouped  = Table.Group(MilestoneSorted, {"ProjectID", "MilestoneHeading"},
        {{"Rows", each _, type table}}),
    MilestoneNumbered = Table.TransformColumns(MilestoneGrouped, {
        {"Rows", each Table.AddIndexColumn(_, "MilestoneNumber", 1, 1, Int64.Type), type table}
    }),
    MilestoneFlat = Table.Combine(MilestoneNumbered[Rows]),
    #"Sorted Rows" = Table.Sort(MilestoneFlat, {
        {"ProjectID", Order.Ascending}, {"HeadingNumber", Order.Ascending},
        {"PlannedStartDate", Order.Ascending}, {"MilestoneID", Order.Ascending}
    })
in
    #"Sorted Rows"

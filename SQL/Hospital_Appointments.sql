

---------------------------------------------------------------------- MEDICAL APPOINTMENT NO-SHOW ANALYSIS







USE Hospital_Analytics;
GO







SELECT 
    (SELECT COUNT(*) FROM [dbo].[MedicalAppointments_Raw]) AS TotalRows,
    (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'MedicalAppointments_Raw') AS TotalColumns;



SELECT TOP 0 * FROM [dbo].[MedicalAppointments_Raw];




EXEC sp_help '[dbo].[MedicalAppointments_Raw]';



SELECT
PatientId,
COUNT(*) AS DuplicateCount
FROM [dbo].[MedicalAppointments_Raw]
GROUP BY PatientId
HAVING COUNT(*) > 1;

SELECT SUM(DuplicateCount - 1) AS TotalDuplicateRows
FROM (
    SELECT COUNT(*) AS DuplicateCount
    FROM [dbo].[MedicalAppointments_Raw]
    GROUP BY [PatientId]
    HAVING COUNT(*) > 1
) AS Duplicates;


-- 1. PREPARE THE COLUMNS WE NEED




--DROP TABLE IF EXISTS #Prepared;



SELECT
    NULLIF(LTRIM(RTRIM(AppointmentID)), '') AS AppointmentID,
    NULLIF(LTRIM(RTRIM(PatientId)), '') AS PatientId,
    NULLIF(LTRIM(RTRIM(Age)), '') AS AgeText,
    TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(Age)), '')) AS AgeValue,
    TRY_CONVERT(DATETIMEOFFSET(0), NULLIF(LTRIM(RTRIM(ScheduledDay)), ''), 127) AS ScheduledAt,
    CAST(TRY_CONVERT(DATETIMEOFFSET(0), NULLIF(LTRIM(RTRIM(AppointmentDay)), ''), 127) AS DATE) AS AppointmentDate,
    NULLIF(LTRIM(RTRIM(Neighbourhood)), '') AS Neighbourhood,
    NULLIF(LTRIM(RTRIM(SMS_received)), '') AS SMSText,
    UPPER(NULLIF(LTRIM(RTRIM([No-show])), '')) AS OutcomeText
INTO #Prepared
FROM dbo.MedicalAppointments_Raw;



-- One row represents an appointment. A patient can have several appointments.




SELECT COUNT(*) AS RawAppointments,
       COUNT(DISTINCT AppointmentID) AS UniqueAppointments,
       COUNT(DISTINCT PatientId) AS UniquePatients
FROM #Prepared;



-- 2. CHECK THE IMPORTANT DATA QUALITY RULES


SELECT
    SUM(CASE WHEN PatientId IS NULL OR AppointmentID IS NULL
              THEN 1 ELSE 0 END) AS InvalidIDs,
    COUNT(AppointmentID) - COUNT(DISTINCT AppointmentID) AS DuplicateAppointments,
    SUM(CASE WHEN ScheduledAt IS NULL OR AppointmentDate IS NULL THEN 1 ELSE 0 END) AS InvalidDates,
    SUM(CASE WHEN (AgeText IS NOT NULL AND AgeValue IS NULL)
              OR AgeValue > 32767 THEN 1 ELSE 0 END) AS InvalidAgeFormat,
    SUM(CASE WHEN SMSText IS NULL OR SMSText NOT IN ('0','1') THEN 1 ELSE 0 END) AS InvalidSMS,
    SUM(CASE WHEN OutcomeText IS NULL OR OutcomeText NOT IN ('YES','NO') THEN 1 ELSE 0 END) AS InvalidOutcome,
    SUM(CASE WHEN Neighbourhood IS NULL OR LEN(Neighbourhood) > 100 THEN 1 ELSE 0 END) AS InvalidNeighbourhood,


    SUM(CASE WHEN AgeValue < 0 THEN 1 ELSE 0 END) AS NegativeAges,
    SUM(CASE WHEN AppointmentDate < CAST(ScheduledAt AS DATE) THEN 1 ELSE 0 END) AS ReversedDates


FROM #Prepared;


-- Review excluded records before creating the Clean table.
SELECT AppointmentID, AgeValue, ScheduledAt, AppointmentDate
FROM #Prepared
WHERE AgeValue < 0 OR AppointmentDate < CAST(ScheduledAt AS DATE)
ORDER BY AppointmentID;



-- 3. CREATE CLEAN DATA WITH THE CORRECT TYPES

IF OBJECT_ID('dbo.MedicalAppointments_Clean', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MedicalAppointments_Clean
    (
        AppointmentID VARCHAR(50) NOT NULL PRIMARY KEY,
        PatientId VARCHAR(50) NOT NULL,
        ScheduledAt DATETIMEOFFSET(0) NOT NULL,
        AppointmentDate DATE NOT NULL,
        Age SMALLINT NULL CHECK (Age >= 0),
        Neighbourhood NVARCHAR(100) NOT NULL,
        SMSReceived BIT NOT NULL,
        NoShowFlag BIT NOT NULL,
        LeadTimeDays INT NOT NULL,
        CHECK (AppointmentDate >= CAST(ScheduledAt AS DATE))
    );

    INSERT INTO dbo.MedicalAppointments_Clean
        (AppointmentID, PatientId, ScheduledAt, AppointmentDate, Age,
         Neighbourhood, SMSReceived, NoShowFlag, LeadTimeDays)
    SELECT
        CAST(AppointmentID AS VARCHAR(50)), CAST(PatientId AS VARCHAR(50)),
        ScheduledAt, AppointmentDate, CAST(AgeValue AS SMALLINT),
        CAST(Neighbourhood AS NVARCHAR(100)), CAST(SMSText AS BIT),
        CAST(CASE OutcomeText WHEN 'YES' THEN 1 WHEN 'NO' THEN 0 END AS BIT),
        DATEDIFF(DAY, CAST(ScheduledAt AS DATE), AppointmentDate)
    FROM #Prepared
    WHERE (AgeValue >= 0 OR AgeValue IS NULL)
      AND AppointmentDate >= CAST(ScheduledAt AS DATE);
END;

SELECT COUNT(*) AS CleanAppointments,
       COUNT(DISTINCT AppointmentID) AS UniqueAppointments,
       COUNT(DISTINCT PatientId) AS Patients,
       SUM(CAST(NoShowFlag AS INT)) AS NoShows
FROM dbo.MedicalAppointments_Clean;





GO

-- 4. ADD USEFUL GROUPS IN ONE VIEW
-- A view is a saved SELECT query. These bands are analytical choices, not clinical rules.



CREATE OR ALTER VIEW dbo.vw_AppointmentAnalysis AS
SELECT *,
    FORMAT(AppointmentDate, 'dddd', 'en-US') AS AppointmentWeekday,
    CASE WHEN Age <= 17 THEN '0-17' WHEN Age <= 34 THEN '18-34'
         WHEN Age <= 49 THEN '35-49' WHEN Age <= 64 THEN '50-64'
         ELSE '65+' END AS AgeGroup,
    CASE WHEN LeadTimeDays = 0 THEN 'Same day'
         WHEN LeadTimeDays <= 7 THEN '1-7 days' WHEN LeadTimeDays <= 14 THEN '8-14 days'
         WHEN LeadTimeDays <= 30 THEN '15-30 days' WHEN LeadTimeDays <= 60 THEN '31-60 days'
         ELSE '61+ days' END AS LeadTimeBand
FROM dbo.MedicalAppointments_Clean;
GO



-- 5. BASELINE: HOW LARGE IS THE NO-SHOW PROBLEM?

SELECT COUNT(*) AS Appointments,
       COUNT(DISTINCT PatientId) AS Patients,
       SUM(CAST(NoShowFlag AS INT)) AS NoShows,
       CAST(1.0 * SUM(CAST(NoShowFlag AS INT)) / NULLIF(COUNT(*),0) AS DECIMAL(9,6)) AS NoShowRate
FROM dbo.vw_AppointmentAnalysis;


-- 6. DOES NO-SHOW RATE DIFFER BY BOOKING LEAD TIME?

SELECT LeadTimeBand, COUNT(*) AS Appointments,
       SUM(CAST(NoShowFlag AS INT)) AS NoShows,
       CAST(100.0 * SUM(CAST(NoShowFlag AS INT)) / COUNT(*) AS DECIMAL(9,2)) AS NoShowRate
FROM dbo.vw_AppointmentAnalysis
GROUP BY LeadTimeBand
ORDER BY MIN(LeadTimeDays);



-- 7. WHICH AGE GROUPS HAVE HIGHER NO-SHOW RATES?


SELECT AgeGroup, COUNT(*) AS Appointments,
       SUM(CAST(NoShowFlag AS INT)) AS NoShows,
       CAST(1.0 * SUM(CAST(NoShowFlag AS INT)) / COUNT(*) AS DECIMAL(9,6)) AS NoShowRate
FROM dbo.vw_AppointmentAnalysis
GROUP BY AgeGroup
ORDER BY NoShowRate Desc;

-- 8. WHICH WEEKDAYS HAVE THE GREATEST MISSED-APPOINTMENT BURDEN?
-- Monday = 1 



SET DATEFIRST 1;
SELECT DATEPART(WEEKDAY, AppointmentDate) AS WeekdayNumber,
       AppointmentWeekday,
       COUNT(DISTINCT AppointmentDate) AS ObservedDates,
       COUNT(*) AS Appointments, SUM(CAST(NoShowFlag AS INT)) AS NoShows,
       CAST(1.0 * SUM(CAST(NoShowFlag AS INT)) / COUNT(*) AS DECIMAL(9,6)) AS NoShowRate,
       CAST(1.0 * SUM(CAST(NoShowFlag AS INT)) / COUNT(DISTINCT AppointmentDate) AS DECIMAL(12,2)) AS AverageNoShowsPerObservedDate
FROM dbo.vw_AppointmentAnalysis
GROUP BY DATEPART(WEEKDAY, AppointmentDate), AppointmentWeekday
ORDER BY WeekdayNumber;

-- 9. WHERE ARE THE MOST APPOINTMENTS MISSED?
-- This is appointment neighbourhood


SELECT TOP (10) Neighbourhood, COUNT(*) AS Appointments,
       SUM(CAST(NoShowFlag AS INT)) AS NoShows,
       CAST(1.0 * SUM(CAST(NoShowFlag AS INT)) / COUNT(*) AS DECIMAL(9,6)) AS NoShowRate
FROM dbo.vw_AppointmentAnalysis
GROUP BY Neighbourhood
HAVING COUNT(*) >= 100
ORDER BY NoShows DESC, NoShowRate DESC, Neighbourhood;




-- 10. HOW DOES ATTENDANCE DIFFER BY SMS STATUS?

SELECT SMSReceived, COUNT(*) AS Appointments,
       SUM(CAST(NoShowFlag AS INT)) AS NoShows,
       CAST(1.0 * SUM(CAST(NoShowFlag AS INT)) / COUNT(*) AS DECIMAL(9,6)) AS NoShowRate
FROM dbo.vw_AppointmentAnalysis
GROUP BY SMSReceived;


-- Compare within age and lead-time bands too. Small groups need careful interpretation.
-- Neither comparison proves that SMS caused a difference in attendance.
SELECT AgeGroup, LeadTimeBand, SMSReceived, COUNT(*) AS Appointments,
       SUM(CAST(NoShowFlag AS INT)) AS NoShows,
       CAST(1.0 * SUM(CAST(NoShowFlag AS INT)) / COUNT(*) AS DECIMAL(9,6)) AS NoShowRate
FROM dbo.vw_AppointmentAnalysis
GROUP BY AgeGroup, LeadTimeBand, SMSReceived
ORDER BY AgeGroup, MIN(LeadTimeDays), SMSReceived;





-- 11. is missed activity concentrated among repeat no-show patients?


WITH PatientSummary AS
(
    SELECT PatientId, COUNT(*) AS Appointments,
           SUM(CAST(NoShowFlag AS INT)) AS NoShows
    FROM dbo.vw_AppointmentAnalysis
    GROUP BY PatientId
)
SELECT CASE WHEN NoShows = 0 THEN '0 missed' WHEN NoShows = 1 THEN '1 missed'
            ELSE '2+ missed' END AS PatientGroup,
       COUNT(*) AS Patients, SUM(Appointments) AS Appointments, SUM(NoShows) AS NoShows,
       CAST(1.0 * SUM(NoShows) / SUM(Appointments) AS DECIMAL(9,6)) AS NoShowRate
FROM PatientSummary
GROUP BY CASE WHEN NoShows = 0 THEN '0 missed' WHEN NoShows = 1 THEN '1 missed'
              ELSE '2+ missed' END
ORDER BY PatientGroup;

-- 12. WHAT IF MISSED APPOINTMENTS FELL BY 10%?
-- Relative reduction: a 20% rate falling by 10% becomes about 18%, not 10%.


DECLARE @Reduction DECIMAL(5,2) = 0.10;
DECLARE @TotalAppointments INT = (SELECT COUNT(*) FROM dbo.vw_AppointmentAnalysis);
DECLARE @MissedAppointments INT = (SELECT SUM(CAST(NoShowFlag AS INT)) FROM dbo.vw_AppointmentAnalysis);
DECLARE @RecoveredAppointments INT = CAST(ROUND(@MissedAppointments * @Reduction, 0) AS INT);

SELECT @Reduction AS AssumedRelativeReduction,
       @MissedAppointments AS CurrentNoShows,
       @RecoveredAppointments AS PotentialRecoveredAppointments,
       @MissedAppointments - @RecoveredAppointments AS ScenarioNoShows,
       CAST(1.0 * (@MissedAppointments - @RecoveredAppointments)
            / NULLIF(@TotalAppointments,0) AS DECIMAL(9,6)) AS ScenarioNoShowRate;






SELECT
    COUNT(*) AS Appointments,
    SUM(CAST(NoShowFlag AS INT)) AS NoShows,
    CAST(1.0 * SUM(CAST(NoShowFlag AS INT))
         / NULLIF(COUNT(*), 0) AS DECIMAL(9,6)) AS NoShowRate,
    CAST(AVG(1.0 * LeadTimeDays) AS DECIMAL(10,2)) AS AverageLeadTimeDays,
    MIN(AppointmentDate) AS FirstAppointmentDate,
    MAX(AppointmentDate) AS LastAppointmentDate
FROM dbo.vw_AppointmentAnalysis;





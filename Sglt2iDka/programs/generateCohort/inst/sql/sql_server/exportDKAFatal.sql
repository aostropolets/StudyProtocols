{@i == 1}?{
  IF OBJECT_ID('@target_database_schema.@target_table') IS NOT NULL
    DROP TABLE @target_database_schema.@target_table;

  CREATE TABLE @target_database_schema.@target_table (
    DB                    VARCHAR(10),
    COHORT_DEFINITION_ID  INT,
    COHORT_OF_INTEREST    VARCHAR(500),
    T2DM                  VARCHAR(10),
    CENSOR                INT,
    DKA                   INT,
    STAT_ORDER_NUMBER     INT,
    STAT_TYPE             VARCHAR(150),
    STAT                  INT,
    STAT_PCT              FLOAT
  );
}


IF OBJECT_ID('tempdb..#qualified_events') IS NOT NULL
  DROP TABLE tempdb..#qualified_events;

IF OBJECT_ID('tempdb..#qualified_events_DKA') IS NOT NULL
  DROP TABLE tempdb..#qualified_events_DKA;

IF OBJECT_ID('tempdb..#TEMP_DATA') IS NOT NULL
  DROP TABLE tempdb..#TEMP_DATA;


/*******************************************************************************/
/****DATA PREP******************************************************************/
/*******************************************************************************/


--HINT DISTRIBUTE_ON_KEY(person_id)
SELECT 	'@dbID' AS DB,
		c.COHORT_DEFINITION_ID,
		u.COHORT_OF_INTEREST,
		u.T2DM,
		u.CENSOR,
		c.SUBJECT_ID AS PERSON_ID,
		c.COHORT_START_DATE,
		c.COHORT_END_DATE,
		p.GENDER_CONCEPT_ID AS GENDER_CONCEPT_ID,
		YEAR(COHORT_START_DATE) - p.YEAR_OF_BIRTH AS AGE,
		op.OBSERVATION_PERIOD_START_DATE,
		op.OBSERVATION_PERIOD_END_DATE
INTO #qualified_events
FROM @target_database_schema.@cohort_universe u
	JOIN @target_database_schema.@cohort_table c
		ON c.COHORT_DEFINITION_ID = u.COHORT_DEFINITION_ID
	JOIN @cdm_database_schema.PERSON p
		ON p.PERSON_ID = c.SUBJECT_ID
	JOIN @cdm_database_schema.OBSERVATION_PERIOD op
		ON op.PERSON_ID = c.SUBJECT_ID
		AND c.COHORT_START_DATE BETWEEN op.OBSERVATION_PERIOD_START_DATE AND op.OBSERVATION_PERIOD_END_DATE
WHERE u.EXPOSURE_COHORT = 1
AND u.FU_STRAT_ITT_PP0DAY = 1;

--HINT DISTRIBUTE_ON_KEY(person_id)
SELECT e.DB, e.COHORT_DEFINITION_ID, e.COHORT_OF_INTEREST, e.T2DM, e.CENSOR,
  e.PERSON_ID, e.COHORT_START_DATE, e.COHORT_END_DATE, e.GENDER_CONCEPT_ID, e.AGE,
	MAX(CASE WHEN c.COHORT_DEFINITION_ID IS NULL THEN 0 ELSE 1 END) AS DKA,
	MIN(c.COHORT_START_DATE) AS DKA_INDEX_DATE
INTO #qualified_events_DKA
FROM #qualified_events e
	LEFT OUTER JOIN @target_database_schema.@cohort_table c
		ON c.SUBJECT_ID = e.PERSON_ID
		AND c.COHORT_DEFINITION_ID = 200 /*DKA (IP & ER)*/
		AND c.COHORT_START_DATE > e.COHORT_START_DATE  /*ITT for DKA*/
		AND c.COHORT_START_DATE BETWEEN e.OBSERVATION_PERIOD_START_DATE AND e.OBSERVATION_PERIOD_END_DATE  /*ITT for DKA*/
GROUP BY e.DB, e.COHORT_DEFINITION_ID, e.COHORT_OF_INTEREST, e.T2DM, e.CENSOR, e.PERSON_ID, e.COHORT_START_DATE, e.COHORT_END_DATE, e.GENDER_CONCEPT_ID, e.AGE;

WITH CTE_COHORT AS (
	SELECT *
	FROM #qualified_events_DKA
	WHERE DKA = 1
),
CTE_TOTALS AS (
	SELECT DB, COHORT_DEFINITION_ID, COHORT_OF_INTEREST,T2DM, CENSOR, DKA, COUNT(DISTINCT PERSON_ID) AS PERSON_COUNT
	FROM CTE_COHORT
	GROUP BY DB, COHORT_DEFINITION_ID,COHORT_OF_INTEREST, T2DM, CENSOR, DKA
)
SELECT *
INTO #TEMP_DATA
FROM (
  SELECT DB, COHORT_DEFINITION_ID, COHORT_OF_INTEREST, T2DM, CENSOR, DKA,
  	1 AS STAT_ORDER_NUMBER,
  	'Total DKA Persons' AS STAT_TYPE,
  	PERSON_COUNT AS STAT,
  	1.0000 AS STAT_PCT
  FROM CTE_TOTALS

  UNION ALL

  SELECT e.DB, e.COHORT_DEFINITION_ID, e.COHORT_OF_INTEREST, e.T2DM, e.CENSOR, e.DKA,
  	2 AS STAT_ORDER_NUMBER,
  	'Discharge Death during first after-index-DKA Visit' AS STAT_TYPE,
  	 COUNT(DISTINCT d.PERSON_ID) AS STAT,
  	 COUNT(DISTINCT d.PERSON_ID)*1.0/t.PERSON_COUNT AS STAT_PCT
  FROM CTE_COHORT e
  	LEFT OUTER JOIN @cdm_database_schema.CONDITION_OCCURRENCE co
  		ON co.PERSON_ID = e.PERSON_ID
  		AND co.CONDITION_START_DATE = e.DKA_INDEX_DATE
  		AND co.CONDITION_CONCEPT_ID IN (
  			SELECT CONCEPT_ID FROM @target_database_schema.@code_list WHERE CODE_LIST_NAME = 'DKA'
  		)
  	LEFT OUTER JOIN @cdm_database_schema.VISIT_OCCURRENCE vo
  		ON vo.PERSON_ID = e.PERSON_ID
  		AND co.VISIT_OCCURRENCE_ID = vo.VISIT_OCCURRENCE_ID
  	LEFT OUTER JOIN @cdm_database_schema.DEATH d
  		ON e.PERSON_ID = d.PERSON_ID
  		AND d.DEATH_DATE BETWEEN vo.VISIT_START_DATE AND vo.VISIT_END_DATE
  		AND d.DEATH_TYPE_CONCEPT_ID = 	38003566 /*	Medical claim discharge status "Died"*/
  	LEFT OUTER JOIN @cdm_database_schema.CONCEPT c
  		ON c.CONCEPT_ID = d.DEATH_TYPE_CONCEPT_ID
  	LEFT OUTER JOIN CTE_TOTALS t
  		ON t.DB = e.DB
  		AND t.COHORT_DEFINITION_ID = e.COHORT_DEFINITION_ID
  		AND t.DKA = e.DKA
  GROUP BY e.DB, e.COHORT_DEFINITION_ID, e.COHORT_OF_INTEREST, e.T2DM, e.CENSOR, e.DKA, t.PERSON_COUNT
) z;


INSERT INTO @target_database_schema.@target_table (DB, COHORT_DEFINITION_ID, COHORT_OF_INTEREST, T2DM, CENSOR, DKA, STAT_ORDER_NUMBER, STAT_TYPE, STAT, STAT_PCT)
SELECT DB, COHORT_DEFINITION_ID, COHORT_OF_INTEREST, T2DM, CENSOR, DKA, STAT_ORDER_NUMBER, STAT_TYPE, STAT, STAT_PCT
FROM #TEMP_DATA;

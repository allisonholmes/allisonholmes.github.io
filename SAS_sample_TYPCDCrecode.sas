***********************************USER INSTRUCTIONS OVERVIEW***************************************

1. In SECTION 1 & 2, Change diagnosis year (DXYR)
2. Highlight & run SECTION 1 -- Import MAVEN data (events) into SAS & check all case count for a given year
3. Highlight and run SECTION 2 -- Import & merge all MAVEN data (events & TYPPTY & enteric) (using left join)
4. Highlight and run SECTION 3 -- Pull MAVEN lab data & merge with all MAVEN data
5. Check and make sure all the MAVEN lab data is complete and logical. Check all suspicious cases in MAVEN and hard code missing lab information.
5. Highlight and run SECTION 3 -- RECODE FOR CDC
6. In SECTION 5, CHANGE THE FILE NAME IN THE DATA STEP
7. Highlight and run SECTION 5 -- CREATING THE EXCEL FILE FOR CDC
8. Export the newly created file into Excel.

******************************************************************************************;

*** USE SERVER: SASApp101 ***;

*** To access WORK library:
	Servers -> SASApp101 -> Libraries -> WORK
	Refresh to see new datasets
***;

libname M odbc noprompt="SERVER=SQLMAVENBCDRPT1;DRIVER=SQL Server Native Client 11.0;Trusted_Connection=YES; 
DATABASE=MAVENBCD" schema=DBO;

libname mav '\\nasprgshare220\Share\DIS\BCD\COMDISshared\Analyst_of_the_week\Maven\SAS_Data'; 
run;


*******************************************************************************************
  SECTION 1 -- Import MAVEN data (events) into SAS & check all case count for a given year
*******************************************************************************************;
data events_check; set mav.MAVEN_EVENTS;
if DISEASE_CODE NE 'TYP' AND DISEASE_CODE  NE 'PTY' THEN DELETE;
DXYR = YEAR(DIAGNOSIS_DATE);
DXMONTH = MONTH(DIAGNOSIS_DATE);
if DXYR in (2021);   ********CHANGE DIAGNOSIS YEARS HERE AS NEEDED***************;
run;

*DATA CLEANING STEP: check each contact, not a case, suspect, and unresolved case is categorized correctly;
proc sql;
	SELECT event_id, disease_status, disease_status_final, investigation_status, 
			interview_status, investigation_notes, onset_date, date_hospitalized, *
	FROM events_check
	WHERE disease_status IN ('CONTACT','NOT_A_CASE','SUSPECT','UNRESOLVED');
quit;run;

proc freq data=events_check;
table disease_status * investigation_status / nopercent norow nocol missing;
where disease_status IN ('CONTACT','NOT_A_CASE','SUSPECT','UNRESOLVED');
quit;run;


******************************************************************************************
  SECTION 2 -- Import & merge all MAVEN data (events & TYPPTY & enteric)
******************************************************************************************;

/* choose between Option 1 and Option 2 */ 

/* OPTION 1: Pulling all eligible cases */
data events; set events_check;
if INVESTIGATION_STATUS IN ('COMPLETE','CONVALESCENT_FOLLOW_UP');
	* make sure any convalescent f/u cases being pulled in have been reviewed;
if DISEASE_STATUS = 'NOT_A_CASE' then delete;
if DISEASE_STATUS_FINAL = 'SUSPECT' then delete; /*delete all suspect/unresolved cases bc no initial lab reports*/
if DISEASE_STATUS_FINAL = 'UNRESOLVED' then delete;
if DISEASE_STATUS_FINAL = 'CONTACT' then delete; /*no contacts*/
if DISEASE_STATUS_FINAL = 'CHRONIC_CARRIER' then delete; /*no chronic carrier cases*/
if BORO = 'OUTSIDE NYC' then delete; /*delete all cases outside of NYC*/ 
run;
* Check disease status and investigation status;
proc freq data=events;
tables DISEASE_STATUS_FINAL*INVESTIGATION_STATUS / missing norow nocol nopercent;
run;


/* OPTION 2: Pulling specific cases*/
/*
	data events; set events_check;
	if EVENT_ID in ('100806527', '100813810'); *change EVTs as neeeded; 
	run;
*/



/* Pull in TYP_PTY question package */ 
data typpty; 
set m.DD_TYP_PTY_ANALYSIS (rename=(BLOOD_CULTURE_COLLECTED_BEFORE_A=temp));
*fixing error 'defined as numeric and character'
	BLOOD_CULTURE_COLLECTED_BEFORE_A - redefined as character;
BLOOD_CULTURE_COLLECTED_BEFORE_A = put(temp, 7.);
drop temp;
run;
/* note that error variable is missing ('.')
	proc freq data=typpty;
	tables BLOOD_CULTURE_COLLECTED_BEFORE_A / missing;
	run;
	*/

/* Pull in ENTERIC question package */ 
data enteric;
set m.DD_ENTERIC_INVESTIGATION
(rename=(TRAVEL_OUTSIDE_COUNTRY_LEFT_US_D=temp1)
	rename=(TRAVEL_OUTSIDE_COUNTRY_ENTERED_D=temp2)
	rename=(TRAVEL_OUTSIDE_COUNTRY_RETURN_DA=temp3));
*fixing errors 'defined as numeric and character': 
	TRAVEL_OUTSIDE_COUNTRY_LEFT_US_D, TRAVEL_OUTSIDE_COUNTRY_ENTERED_D, TRAVEL_OUTSIDE_COUNTRY_RETURN_DA
	redefining as numeric dates;
TRAVEL_OUTSIDE_COUNTRY_LEFT_US_D = input(temp1, date9.);
	TRAVEL_OUTSIDE_COUNTRY_ENTERED_D = input(temp2, date9.);
	TRAVEL_OUTSIDE_COUNTRY_RETURN_DA = input(temp3, date9.);
if DISEASE_CODE NE 'TYP' AND DISEASE_CODE  NE 'PTY' THEN DELETE;
keep EVENT_ID INTERVIEW_DT REPORT_TO_CDC REPORT_TO_CDC_DATE;
run;
/**note that error variables are dropped from the dataset anyways - only keeping whether already reported to CDC;
	proc freq data=enteric; tables TRAVEL_OUTSIDE_COUNTRY_LEFT_US_D / missing; run;
	proc freq data=enteric; tables TRAVEL_OUTSIDE_COUNTRY_ENTERED_D / missing; run;
	proc freq data=enteric; tables TRAVEL_OUTSIDE_COUNTRY_RETURN_DA / missing; run;
*/

/*Sort datasets by EVT*/
proc sort data=events;
by EVENT_ID;
run;
proc sort data=typpty;
by EVENT_ID;
run;
proc sort data=enteric;
by EVENT_ID;
run;

/*Merge datasets by EVT*/
data merged_maven;
merge events (in=a)  
		typpty enteric; *keeping cases in filtered EVENTS dataset;
by EVENT_ID;
if a;
run;



*************************************************************************
  SECTION 3 -- Pull MAVEN lab data & merge with all MAVEN data
*************************************************************************;

/*Pulling LAB data*/
data lab; set m.DD_AOW_LABS;
if DISEASE_CODE NE 'TYP' AND DISEASE_CODE  NE 'PTY' THEN DELETE;
run;

/*Cases with a positive culture from ANY LAB should be reported
 Start with culture results from PHL (most common) */

proc sql ;  * select variables of interest, filter to only cases present in EVENTS dataset;
 CREATE TABLE lab_filtered AS
	SELECT DISTINCT(EVENT_ID), SPECIMEN_DATE, SPECIMEN_NUMBER, SPECIMEN_SOURCE_NAME, RESULT_NAME, result_description,
					LAB_CLIA, LAB_NAME 
 	FROM lab
	WHERE event_id IN (
		SELECT event_id
		FROM events)
	ORDER BY EVENT_ID, SPECIMEN_DATE;
quit;

/*Table filtered to PHL lab data (NYC PHL and NYS Wadsworth)*/
data lab_PHL; set lab_filtered;
if LAB_CLIA ne '33D0679872' and LAB_CLIA ne '33D0654341' THEN DELETE; 
run;

/*Table filtered to typing results*/
data lab_type; set lab_PHL;
if find(result_name, 'typhi', 'i') ge 1; *scans typhi or paratyphi;
if find(result_name, 'negative', 'i') ge 1  
	OR find(result_name, 'suspicious', 'i') ge 1
	OR find(result_description, 'suspicious', 'i') ge 1 THEN DELETE; *omit negative, non-confirmatory tests;
run;

/*CHECK - Sort so first result is pulled correctly
		  Earliest collection date, Blood specimen (if available), serotype in RESULT_NAME*/
proc sort data=lab_type;
by EVENT_ID SPECIMEN_DATE SPECIMEN_SOURCE_NAME RESULT_NAME; 
	* Blood will sort before other specimen sources;
	* 'Salmonella' will sort before 'See observation' or 'Suspicious' results;
run; 
*** Look through lab results to make sure first result for each EVT is the one we want to pull;

/*Take only first result per case*/
proc sort data=lab_type out=lab_final nodupkey;
by EVENT_ID;
run; 


/*Check if any results did not pull in TYP/PTY species - no serotype from PHL*/
proc sql;
CREATE TABLE lab_noPHL AS
	SELECT *
	FROM lab_filtered
	WHERE event_id NOT IN(
		SELECT event_id
		FROM lab_final);
quit;run;
	*103193875 reported from FL PHL;
	*103665904 PHL testing was negative so will report result from private lab;


/*Filter and join to add these labs to LAB_FINAL dataset*/
data lab_noPHL_type; set lab_noPHL;
if find(result_name, 'typhi', 'i') ge 1;
if find(result_name, 'negative', 'i') ge 1 THEN DELETE;
	*if an EVT still has multiple results MANUALLY keep only confirmatory test;
	if event_id = '103193875' AND specimen_number NE 'JBS21004518' THEN DELETE;
run;

/*Merge to final dataset*/
data lab_final;
merge lab_noPHL_type lab_final;  *full join;
by EVENT_ID;
run;


/*Double check if any results did not pull in TYP/PTY species (should be blank)*/
proc sql;
	SELECT *
	FROM lab_filtered
	WHERE event_id NOT IN(
		SELECT event_id
		FROM lab_final);
quit;run;
proc sql;
	SELECT *
	FROM merged_maven
	WHERE event_id NOT IN(
		SELECT event_id
		FROM lab_final);
quit;run;


*************************************************************************************
        MERGE LAB DATA TO EVT DATA
*************************************************************************************;
data merged;
merge merged_maven (in=a) lab_final; by EVENT_ID;
if a;
*if REPORT_TO_CDC = 'No' or REPORT_TO_CDC = ' ';  *comment out this line for year-end data closeout;
run;

* Check any cases with REPORT_TO_CDC = 'No' to see if they need to be omitted from the report;
proc sql;
	SELECT EVENT_ID, REPORT_TO_CDC, *
	FROM merged
	ORDER BY REPORT_TO_CDC;
run;

/* Check for correct results pulled in */
proc freq data= merged; 
table disease_status; run; 

proc freq data=merged;
table specimen_date; run; 

proc print data =  merged;
var event_id REPORT_TO_CDC specimen_date specimen_number specimen_source_name result_name 
	lab_clia lab_name; 
run;


/*Create serotype from lab results*/
data merged; length serotype $30.; set merged;
IF RESULT_NAME='Salmonella Typhi' then serotype = 'TYPHI';
ELSE IF RESULT_NAME='Salmonella Paratyphi A' then serotype = 'PARATYPHI A';
	ELSE IF find(RESULT_DESCRIPTION, 'Paratyphi A', 'i') ge 1 then serotype = 'PARATYPHI A';
*PTY B and C are rare, may need to recode if these appear;
	ELSE IF RESULT_NAME='Salmonella Paratyphi B' then serotype = 'PARATYPHI B';
	ELSE IF RESULT_NAME='Salmonella Paratyphi C' then serotype = 'PARATYPHI C';
run;

proc freq data=merged; 
table serotype / missing; run; 
*Make sure all serotype information is present before proceeding; 


*IF serotype or other fields are missing, use code below as necessary to hard code;
* need fields - SEROTYPE, SPECIMEN_DATE, SPECIMEN_SOURCE_NAME for each entry ;
/*
	data merged; set merged;
	*if EVENT_ID='102762143' then SPECIMEN_DATE = input('12JUN2021:00:00:00.000', DATETIME22.3);
	*if EVENT_ID='102762143' then SPECIMEN_SOURCE_NAME = 'Blood';
	*if EVENT_ID='102762143' then RESULT_NAME = 'Salmonella Typhi';

	*if EVENT_ID='103193875' then serotype = 'TYPHI';

	if EVENT_ID='103665904' then DELETE; * delete cases we are not reporting;

	run;
*/


*************************************************************************
  SECTION 4 -- RECODE FOR CDC
*************************************************************************;

data merged_recode;
/* Set lengths, formats */
LENGTH stateepi $ 30 slabsid $30 slabsid2 $30 state $3 name $3 dob 8 age 8 sex 8 foodhand 8 citizen $50 othcitzn $50 
       ill 8 dtonset 8 hosp 8 hospdays 8 outcome 8 dtisol 8 site 8 othsite $30 serotype $30 
	   sensi 8 ampr 8 chlorr 8 tmpsmxr 8 quinol 8
       outbreak 8 vac5yr 8 stanvax 8 yrstanvax 8 ty21vax 8 yrty21 8 vicps 8 yrvicps 8
	   outus 8 country1 $50 country2 $50 country3 $50 country4 $50 country1oth $50 country2oth $50 country3oth $50 country4oth $100 
	   dtentus 8 business 8 tourism 8 visitfam 8 immigrat 8 othtrav 8 travreas $30
       anycarr 8 prevcarr 8 comment $100 dtform 8;

FORMAT stateepi $30. slabsid $30. slabsid2 $30. state $3. name $3. dob MMDDYY8. age 11. sex 11. foodhand 11. citizen $50. othcitzn $50.
       ill 11. dtonset MMDDYY8. hosp 11. hospdays 11. outcome 11. dtisol MMDDYY8. site 11. othsite $30. serotype $30. 
	   sensi 11. ampr 11. chlorr 11. tmpsmxr 11. quinol 11. 
	   outbreak 11. vac5yr 11. stanvax 11. yrstanvax 11. ty21vax 11. yrty21 11. vicps 11. yrvicps 11.
	   outus 11. country1 $50. country2 $50. country3 $50. country4 $50. country1oth $50. country2oth $50. country3oth $50. country4oth $100.
	   dtentus MMDDYY8. business 11. tourism 11. visitfam 11. immigrat 11. othtrav 11. travreas $30.
	   anycarr 4. prevcarr 4. comment $100. dtform MMDDYY8. ;

INFORMAT stateepi $30. slabsid $30. slabsid2 $30. state $3. name $3. dob datetime19. age 11. sex 11. foodhand 11. citizen $50. othcitzn $50.
       ill 11. dtonset datetime19. hosp 11. hospdays 11. outcome 11. dtisol datetime19. site 11. othsite $30.
	   serotype $30. sensi 11. ampr 11. chlorr 11. tmpsmxr 11. quinol 11.
	   outbreak 11. vac5yr 11. stanvax 11. yrstanvax 11. ty21vax 11. yrty21 11. vicps 11. yrvicps 11.
	   outus 11. country1 $50. country2 $50. country3 $50. country4 $50. country1oth $50. country2oth $50. country3oth $50. country4oth $100.
	   dtentus datetime19. business 11. tourism 11. visitfam 11. immigrat 11. othtrav 11. travreas $30.
	   anycarr 4. prevcarr 4. comment $100. dtform datetime19.;

set merged
	(rename= (slabsid2=temp1 othsite=temp2 country4oth=temp3 travreas=temp4 comment=temp5));
/*Fix errors 'defined as numeric and character' */
		slabsid2 = put(temp1, 7.);
		othsite = put(temp2, 7.);
		country4oth = put(temp3, 7.);
		travreas = put(temp4, 7.);
		comment = put(temp5, 7.);
	drop temp1 temp2 temp3 temp4 temp5;


/* Recode CDC variables */

/*ID variables*/
   stateepi=input(EVENT_ID, $30.);
   slabsid=scan(SPECIMEN_NUMBER,1,'-');

/*Reporting state*/
	state= 'NY';

/*First three letters of patient's last name*/
*** WE ARE NOT REPORTING NAME TO CDC PER HAENA ***;
	*name = substr(LAST_NAME, 1, 3);
	name = '';

/*Date of birth*/
   dob=input(BIRTH_DATE, 19.);

/*Age ??????*/

/*Sex*/
sex=.;
if GENDER='MALE' then sex=1;
else if GENDER='FEMALE' then sex=2;
else if GENDER='UNKNOWN' then sex=9;
else sex=3; *Other;

/*Work as foodhandler?*/
foodhand=3;
if WORK_FOOD_HANDLING='Yes' then foodhand=1;
else if WORK_FOOD_HANDLING='No' then foodhand=2;
else if WORK_FOOD_HANDLING='Unknown' then foodhand=9;

/*Citizenship*/
* we do not collect citizenship information in interview;
citizen='';
othcitzn='';

/*Symptomatic with enteric fever*/
ill=3;
if SYMPTOMATIC='YES' then ill=1;
else if SYMPTOMATIC='NO' then ill=2;
else if SYMPTOMATIC='UNKNOWN' then ill=9;

/*Date of symptom onset*/
rename SYMPTOM_ONSET_DATE = dtonset;

/*Hospitalized?*/
hosp=3;
if find(CASE_HOSPITALIZED,'YES')>0 then hosp=1;
else if CASE_HOSPITALIZED='NO' then hosp=2;
else if CASE_HOSPITALIZED='UNKNOWN' then hosp=9;

/*Days hospitalized*/
* separate hospitalizations - up to 4;
   DATE_HOSPITALIZED_1_temp=scan(DATE_HOSPITALIZED,1,',');
   DATE_HOSPITALIZED_1=input(DATE_HOSPITALIZED_1_temp, MMDDYY10.);
   DATE_DISCHARGED_1_temp=scan(DATE_DISCHARGED,1,',');
   DATE_DISCHARGED_1=input(DATE_DISCHARGED_1_temp, MMDDYY10.);
   DATE_HOSPITALIZED_2_temp=scan(DATE_HOSPITALIZED,2,', ');
   DATE_HOSPITALIZED_2=input(DATE_HOSPITALIZED_2_temp, MMDDYY10.);
   DATE_DISCHARGED_2_temp=scan(DATE_DISCHARGED,2,', ');
   DATE_DISCHARGED_2=input(DATE_DISCHARGED_2_temp, MMDDYY10.);
   DATE_HOSPITALIZED_3_temp=scan(DATE_HOSPITALIZED,3,', ');
   DATE_HOSPITALIZED_3=input(DATE_HOSPITALIZED_3_temp, MMDDYY10.);
   DATE_DISCHARGED_3_temp=scan(DATE_DISCHARGED,3,', ');
   DATE_DISCHARGED_3=input(DATE_DISCHARGED_3_temp, MMDDYY10.);
   DATE_HOSPITALIZED_4_temp=scan(DATE_HOSPITALIZED,4,', ');
   DATE_HOSPITALIZED_4=input(DATE_HOSPITALIZED_4_temp, MMDDYY10.);
   DATE_DISCHARGED_4_temp=scan(DATE_DISCHARGED,4,', ');
   DATE_DISCHARGED_4=input(DATE_DISCHARGED_4_temp, MMDDYY10.);

	hospdays_1=(DATE_DISCHARGED_1-DATE_HOSPITALIZED_1);
	hospdays_2=(DATE_DISCHARGED_2-DATE_HOSPITALIZED_2);
	hospdays_3=(DATE_DISCHARGED_3-DATE_HOSPITALIZED_3);
	hospdays_4=(DATE_DISCHARGED_4-DATE_HOSPITALIZED_4);
* sum days of all hospitalizations;
hospdays = SUM(hospdays_1, hospdays_2, hospdays_3, hospdays_4);

/*Outcome of case*/
outcome=.;
if CURRENTLY_ALIVE='YES' then outcome=1;
else if CURRENTLY_ALIVE='NO' then outcome=2;
else if CURRENTLY_ALIVE='UNKNOWN' then outcome=9;

/*Date of specimen collection*/
dtisol=input(SPECIMEN_DATE_temp, 19.);

/*Sites of isolation*/
site=.;
if SPECIMEN_SOURCE_NAME='Blood' then site=1;
else if SPECIMEN_SOURCE_NAME='Stool' then site=2;
else if SPECIMEN_SOURCE_NAME='Gallbladder' then site=4;
else if SPECIMEN_SOURCE_NAME='Gall bladder' then site=4;
else if SPECIMEN_SOURCE_NAME='Urine' then site=5;
else if SPECIMEN_SOURCE_NAME='Unknown' then site=9;
else site=6; *Other;
	if site=6 then othsite = SPECIMEN_SOURCE_NAME;

/*Serotype recoded in LAB steps, SECTION 3*/

/*Was antimicrobial sensitivity testing done at state PHL?*/
sensi=.;
if ANTIBIOTIC_SUSCEPTIBILITY_TESTIN='Yes' then sensi=1;
else if ANTIBIOTIC_SUSCEPTIBILITY_TESTIN='No' then sensi=2;
else if ANTIBIOTIC_SUSCEPTIBILITY_TESTIN='Unknown' then sensi=9;

/*Resistant to ampicillin, chloramphenicol, trimethoprim-sulfamethoxazole, fluoroquinolone?*/
ampr =.; chlorr =.; tmpsmxr =.;quinol =.;

if ANTIBIOTIC_SUSCEPTIBILITY_TESTIN='Unknown' then ampr= 9;
if ANTIBIOTIC_SUSCEPTIBILITY_TESTIN='Unknown' then chlorr= 9;
if ANTIBIOTIC_SUSCEPTIBILITY_TESTIN='Unknown' then tmpsmxr= 9;
if ANTIBIOTIC_SUSCEPTIBILITY_TESTIN='Unknown' then quinol= 9;

array abx {*} $ANTIBIOTIC_TESTED1-ANTIBIOTIC_TESTED12;
array abxres {*} $ANTIBIOTIC_SUSC_RESULT1-ANTIBIOTIC_SUSC_RESULT12;
do i=1 to dim(abx);
   if ampr =. and abx[i] = 'Ampicillin' and abxres[i] = 'Resistant' then ampr = 1;
   if ampr =. and abx[i] = 'Ampicillin' and abxres[i] ne 'Resistant' then ampr = 2;
   if chlorr =. and abx[i] = 'Chloramphenicol' and abxres[i] = 'Resistant' then chlorr = 1;
   if chlorr =. and abx[i] = 'Chloramphenicol' and abxres[i] ne 'Resistant' then chlorr = 2;
   if tmpsmxr =. and abx[i] = 'Trimethoprim - Sulfamethoxazole (Bactrim, Septra, co-trimoxazole, TMP SMX)' and abxres[i] = 'Resistant' then tmpsmxr = 1;
   if tmpsmxr =. and abx[i] = 'Trimethoprim - Sulfamethoxazole (Bactrim, Septra, co-trimoxazole, TMP SMX)' and abxres[i] ne 'Resistant' then tmpsmxr = 2;
   if quinol =. and abx[i]= 'Ciprofloxacin (Cipro)' and abxres[i] = 'Resistant' then quinol = 1;
   if quinol =. and abx[i]= 'Ciprofloxacin (Cipro)' and abxres[i] ne 'Resistant' then quinol = 2;
   retain _all_;
end;

if ANTIBIOTIC_SUSCEPTIBILITY_TESTIN='Yes' and ampr =. then ampr = 7;
if ANTIBIOTIC_SUSCEPTIBILITY_TESTIN='Yes' and chlorr =. then chlorr = 7;
if ANTIBIOTIC_SUSCEPTIBILITY_TESTIN='Yes' and tmpsmxr =. then tmpsmxr = 7;
if ANTIBIOTIC_SUSCEPTIBILITY_TESTIN='Yes' and quinol =. then quinol= 7;

/*Did case occur as part of outbreak (either domestically or abroad)?*/
outbreak=.;
if outbreak_investigation='Yes' then outbreak=1;
else if outbreak_investigation='No' then outbreak=2;
else if outbreak_investigation='Unknown' then outbreak=9;

/*Vaccinated within the last 5 years?*/
vac5yr=3;
if VACCINATED='Yes' then vac5yr=1;
else if VACCINATED='No' then vac5yr=2;
else if VACCINATED='Unknown' then vac5yr=9;

/*Standard killed typhoid shot*/
stanvax=.;

/*Year of standard killed typhoid shot*/
yrstanvax=.;

/*Oral Ty21a or Vivotif (four pill series)*/
ty21vax=.;

/*Year of Oral Ty21a or Vivotif four pill series received*/
yrty21=.;

/*VICPS or TyphimVI injection*/
vicps=.;

/*Year VICPS or TyphimVI injection received*/
yrvicps=.;

/*Travel outside of US in 30 days prior to illness onset?*/
outus=3;
if TRAVEL_OUTSIDE_COUNTRY='YES' then outus=1;
else if TRAVEL_OUTSIDE_COUNTRY='NO' then outus=2;
else if TRAVEL_OUTSIDE_COUNTRY='UNKNOWN' then outus=9;

/*Countries visited in chronological order*/
* separate countries;
country1=scan(TRAVEL_OUTSIDE_COUNTRY_COUNTRY,1,',');
country2=scan(TRAVEL_OUTSIDE_COUNTRY_COUNTRY,2,',');
country3=scan(TRAVEL_OUTSIDE_COUNTRY_COUNTRY,3,',');
country4=scan(TRAVEL_OUTSIDE_COUNTRY_COUNTRY,4,',');

country1oth=.;
country2oth=.;
country3oth=.;

*get position of 4th comma in TRAVEL_OUTSIDE_COUNTRY_COUNTRY to pass in;
  search_term = ','; nth_time = 2; counter = 0; last_find = 0;
  start = 1;
  pos = find(TRAVEL_OUTSIDE_COUNTRY_COUNTRY,search_term,'',start);
  do while (pos gt 0 and nth_time gt counter);
    last_find = pos;
    start = pos + 1;
    counter = counter + 1;
    pos = find(TRAVEL_OUTSIDE_COUNTRY_COUNTRY,search_term,'',start+1)+2;
  end;
*list of >4 countries to country4oth variable;
	if count(TRAVEL_OUTSIDE_COUNTRY_COUNTRY,',') > 3 then
	country4 = 'Other';
	if count(TRAVEL_OUTSIDE_COUNTRY_COUNTRY,',') > 3 then
	country4oth = substr(TRAVEL_OUTSIDE_COUNTRY_COUNTRY, pos);

/*Date of most recent return/entry to US */
dtentus=input(TRAVEL_OUTSIDE_COUNTRY_RETURN_DA, 19.);

/*Purpose of international travel */
business=.;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Business') ge 1 then business=1;
else if TRAVEL_OUTSIDE_COUNTRY_REASON='Unknown' then business=9;
else if outus=1 then business=2;

tourism=.;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Tourism/Vacation/Recreation') ge 1 then tourism=1;
else if TRAVEL_OUTSIDE_COUNTRY_REASON='Unknown' then tourism=9;
else if outus=1 then tourism=2;

visitfam=.;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'To visit friends and relatives') ge 1 then visitfam=1;
else if TRAVEL_OUTSIDE_COUNTRY_REASON='Unknown' then visitfam=9;
else if outus=1 then visitfam=2;

immigrat=.;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Immigrant/Refugee') ge 1 then immigrat=1;
if TRAVEL_OUTSIDE_COUNTRY_REASON='Unknown' then immigrat=9;
else if outus=1 then immigrat=2;

othtrav=.;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Reside there') ge 1 then othtrav=1;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Peace Corps') ge 1 then othtrav=1;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Airline/ Ship Crew') ge 1 then othtrav=1;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Missionary or dependent') ge 1 then othtrav=1;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Owned 2nd residence') ge 1 then othtrav=1;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Student/Teacher') ge 1 then othtrav=1;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Military') ge 1 then othtrav=1;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Wedding') ge 1 then othtrav=1;
if find(TRAVEL_OUTSIDE_COUNTRY_REASON,'Other') ge 1 then othtrav=1;
else if TRAVEL_OUTSIDE_COUNTRY_REASON='Unknown' then othtrav=9;
else if outus=1 then othtrav=2;

*travreas;
if othtrav = 1 then travreas = TRAVEL_OUTSIDE_COUNTRY_REASON;
* may need additional string manipulation / hard code if 'other' + additional reasons;

/*Case traced to asymptomatic carrier?*/
anycarr=.;
if TRACED_TO_CARRIER='YES' then anycarr=1;
else if TRACED_TO_CARRIER='NO' then anycarr=2;
else if TRACED_TO_CARRIER='UNKNOWN' then anycarr=9;
else if TRACED_TO_CARRIER=' ' then anycarr=3;

/*Carrier previously known to health department?*/
prevcarr=.;
if TRACED_TO_CARRIER='YES' then prevcarr=1;
else if TRACED_TO_CARRIER='NO' then prevcarr=2;
else if TRACED_TO_CARRIER='UNKNOWN' then prevcarr=9;
else if TRACED_TO_CARRIER=' ' then prevcarr=3;

/*Date health department completed form*/
INTERVIEW_DT_temp=datepart(INTERVIEW_DT);
dtform=input(INTERVIEW_DT_temp, 19.);

/*Comments*/
if dtform =. and INTERVIEW_STATUS ne 'Complete' then comment='Not interviewed';

run;



/*Check variables with multiple values - HOSPITALIZATION and TRAVEL*/
/*Also check VACCINATION info*/
proc print data=merged_recode noobs;
var EVENT_ID CASE_HOSPITALIZED DATE_HOSPITALIZED DATE_DISCHARGED hospdays 
DATE_HOSPITALIZED_1 DATE_DISCHARGED_1 hospdays_1
DATE_HOSPITALIZED_2 DATE_DISCHARGED_2 hospdays_2
DATE_HOSPITALIZED_3 DATE_DISCHARGED_3 hospdays_3
DATE_HOSPITALIZED_4 DATE_DISCHARGED_4 hospdays_4;
run;
proc print data=merged_recode noobs;
var EVENT_ID TRAVEL_OUTSIDE_COUNTRY_COUNTRY country1 country2 country3 country4 country4oth
TRAVEL_OUTSIDE_COUNTRY_REASON business tourism visitfam immigrat othtrav travreas 
TRAVEL_OUTSIDE_COUNTRY_NOTES;
run; 
proc print data=merged_recode noobs;
var EVENT_ID vac5yr stanvax yrstanvax ty21vax yrty21 vicps yrvicps
VACCINATED VACCINE VACCINE_OTHER_DESC VACCINE_NUMBER_DOSES VACCINE_STATUS 
VACCINE_RECENT_DOSE_DATE_TEXT VACCINE_TESTED_AFTER_RECENT_DOSE VACCINE_MANUFACTURER VACCINE_REASON 
VACCINE_TYPE VACCINE_TYPE_OTHER_DESC VACCINE_TYP_5_YEARS_BEFORE_ILLNE VACCINE_TYPE_TXT 
VACCINE_DOSE_1_TIMEFRAME VACCINE_DOSE_1_DATE VACCINE_DOSE_2_TIMEFRAME VACCINE_DOSE_2_DATE;
run;
/*Check if hard coding is needed for variables with multiple values
	may have to hard code type, year if pt was vaccinated*/


/*HARD CODE cases with multiple values not pulled in correctly*/
/*
	DATA merged_recode;
	SET merged_recode;
	*if EVENT_ID='101928089' then hospdays=9;
	*if EVENT_ID='105272788' then tourism=1;
	*if EVENT_ID='100723101' then visitfam=1;
	*if EVENT_ID='100739113' then othtrav=1;
	*if EVENT_ID='100739113' then travreas='Give birth';
RUN;
*/


/*Label and filter to only CDC variables*/
DATA recode; 
*RETAIN stateepi slabsid slabsid2 state name dob age sex foodhand citizen othcitzn ill dtonset hosp hospdays outcome dtisol site othsite serotype sensi ampr chlorr tmpsmxr quinol outbreak vac5yr stanvax yrstanvax ty21vax yrty21 vicps yrvicps 
outus country1 country2 country3 country4 country1oth country2oth country3oth country4oth dtentus business tourism visitfam immigrat othtrav travreas anycarr prevcarr comment dtform REPORT_TO_CDC;
SET merged_recode;
LABEL stateepi = 'State health department case ID'
slabsid = 'State public health lab isolate ID'
state = 'Reporting state '
name = 'First three letters of patients last name'
dob = 'Date of birth '
age = 'Age (in years)'
sex = 'Sex'
foodhand = 'Work as foodhandler?'
citizen = 'Citizenship'
othcitzn = 'Specify citizenship (if not in country list)'
ill = 'Symptomatic with enteric fever'
dtonset = 'Date of symptom onset'
hosp = 'Hospitalized?'
hospdays = 'Days hospitalized'
outcome = 'Outcome of case'
dtisol = 'Date of specimen collection'
site = 'Sites of isolation'
othsite = 'If site of isolation is “other”, please specify'
serotype = 'Serotype'
sensi = 'Was antimicrobial sensitivity testing done at state PHL?'
ampr = 'Resistant to ampicillin?'
chlorr = 'Resistant to chloramphenicol?'
tmpsmxr = 'Resistant to trimethoprim-sulfamethoxazole?'
quinol = 'Resistant to fluoroquinolone?'
outbreak = 'Did case occur as part of outbreak (either domestically or abroad)?'
vac5yr = 'Vaccinated within the last 5 years?'
stanvax = 'Standard killed typhoid shot'
yrstanvax = 'Year of standard killed typhoid shot'
ty21vax = 'Oral Ty21a or Vivotif (four pill series)'
yrty21 = 'Year of Oral Ty21a or Vivotif four pill series received'
vicps = 'VICPS or TyphimVI injection'
yrvicps = 'Year VICPS or TyphimVI injection received'
outus = 'Travel outside of US in 30 days prior to illness onset?'
country1 = 'First country visited (in chronological order)'
country2 = 'Second country visited (in chronological order)'
country3 = 'Third country visited (in chronological order)'
country4 = 'Fourth country visited (in chronological order)'
dtentus = 'Date of most recent return or entry in the US'
business = 'Business is purpose of international travel'
tourism = 'Tourism is purpose of international travel'
visitfam = 'Visiting relatives and/or friends is purpose of international travel'
immigrat = 'Immigration to the US is purpose of international travel'
othtrav = 'Other travel is purpose of international travel'
travreas = 'Reason for other travel'
anycarr = 'Case traced to asymptomatic carrier?'
prevcarr = 'Carrier previously known to health department?'
comment = 'Comments'
dtform = 'Date health department completed form'
REPORT_TO_CDC = 'Case reported to CDC? (MAVEN)';

keep stateepi slabsid slabsid2 state name dob age sex foodhand citizen othcitzn ill dtonset hosp hospdays outcome dtisol site othsite serotype sensi ampr chlorr tmpsmxr quinol outbreak vac5yr stanvax yrstanvax ty21vax yrty21 vicps yrvicps 
outus country1 country2 country3 country4 country1oth country2oth country3oth country4oth dtentus business tourism visitfam immigrat othtrav travreas anycarr prevcarr comment dtform REPORT_TO_CDC;

run;

*Check report to CDC again - should be blank or double check No;
proc sql;
	SELECT REPORT_TO_CDC, *
	FROM recode;
quit;run;

/*Drop REPORT_TO_CDC*/
data recode; set recode;
drop REPORT_TO_CDC;
run;



*************************************************************************
  SECTION 5 -- CREATING THE EXCEL FILE FOR CDC
*************************************************************************;

*********************************************
1. CHANGE THE FILE NAME IN THE DATA STEP
2. EXPORT FILE INTO EXCEL
3. CHANGE IN MAVEN'S ADMINISTRATIVE TAB FOR "REPORT/SENT CASE FORMS TO CDC" TO YES AND UPDATE THE "DATE LAST SENT" AFTER SUDHA SENDS TO CDC;
**********************************************;

/*Change to folder you want to save file in*/
LIBNAME CDC '\\nasprgshare220\Share\DIS\BCD\COMDISshared\Foodborne\Disease-specific folders\S. Typhi\CDC forms\Electronic Files sent to CDC\2023';
libname closeout'\\nasprgshare220\Share\DIS\BCD\COMDISshared\Foodborne\Disease-specific folders\S. Typhi\CDC forms\Data closeout/2023';

*******CHANGE FILE NAME TO CORRECT MONTH AND YEAR******;
DATA CDC.NYC_TyphiCases_2021_closeout_mav; set merged_recode;
run;

DATA CDC.NYC_TyphiCases_2021_closeout; set recode;
run;


*******CHANGE FILE NAME TO CORRECT MONTH AND YEAR******;
PROC EXPORT DATA= CDC.NYC_TyphiCases_2021_closeout
OUTFILE= "\\nasprgshare220\Share\DIS\BCD\COMDISshared\Foodborne\Disease-specific folders\S. Typhi\CDC forms\Data closeout\2023\NYC_TyphiCases_2021.xls"
DBMS=EXCEL REPLACE; SHEET="NYC_TyphiCases"; /*edit path*/
RUN;


/***AFTER HAENA SUBMITS TO CDC -
	CHANGE MAVEN's [Administrative] "Report/Sent case forms to CDC" TO YES"
	UPDATE "Date last sent"
***/


/*CHECK that all cases reported in last data pull have been updated*/
	* join to .SAS file of last pull - CDC.NYC_TyphiCases_2021_2022;
proc sql;
	SELECT stateepi AS event_id, REPORT_TO_CDC, REPORT_TO_CDC_DATE 
	FROM CDC.NYC_TyphiCases_2021_2022 AS report
		LEFT JOIN m.DD_ENTERIC_INVESTIGATION AS updated_status
		ON report.stateepi = updated_status.event_id;
quit;run;


* Check status of reported cases - investigation status should be COMPLETE;
proc print data=merged_maven;
where BORO NE 'OUTSIDE NYC' AND
		REPORT_TO_CDC = 'Yes';
var event_id disease_status dxyr disease_status_final investigation_status interview_status boro;
run;
*&---------------------------------------------------------------------*
*& Report  : ZIBP_PDS_COPY_LOGSYS
*& Author  : Praveen Guduru
*& Purpose : Copy IBP source-of-supply (PDS) records whose ZZAPPL = '1'
*&           from logical system EDI to logical system TDS.
*&
*&           The program targets three tables:
*&             /IBP/SOSHEAD_EXT  -  SOS header
*&             /IBP/SOSBOM_EXT   -  SOS bill-of-material
*&             /IBP/SOSACT_EXT   -  SOS activity
*&
*&           Processing steps
*&           ----------------
*&           1. Delete every existing TDS+ZZAPPL=1 row from all three
*&              tables (commit immediately so later inserts see a clean
*&              state and produce no duplicate-key errors).
*&           2. Read the EDI+ZZAPPL=1 rows in fixed-size packages.
*&           3. Hand each package to a free SPBT work process that
*&              overwrites LOGSYS='TDS' and inserts the copies in its
*&              own LUW.
*&
*& Note    : LOGSYS is part of the primary key of all three tables, so
*&           EDI rows and their TDS copies have different keys.
*&           Flipping LOGSYS is therefore a safe insert, not an update,
*&           once the stale TDS rows have been removed.
*&---------------------------------------------------------------------*
REPORT zibp_pds_copy_logsys.

*&---------------------------------------------------------------------*
*& Selection screen
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-b01.
PARAMETERS:
  "-- RFC server group that provides the parallel work processes (SM54)
  p_group TYPE spta_rfcgr      DEFAULT 'parallel_generators',
  "-- Number of rows dispatched to each parallel work process
  p_pkg   TYPE i               DEFAULT 100000,
  "-- Maximum number of parallel work processes to use simultaneously
  p_npar  TYPE i               DEFAULT 1,
  "-- Test run: count rows only, make no database changes
  p_test  TYPE abap_bool AS CHECKBOX.
SELECTION-SCREEN END OF BLOCK b1.

*&---------------------------------------------------------------------*
*& Internal table types for the RFC payload
*& (IBP does not always ship ready-made table types, so we define our
*&  own to pass data across the RFC boundary to the worker FM.)
*&---------------------------------------------------------------------*
TYPES:
  tt_soshead TYPE STANDARD TABLE OF /ibp/soshead_ext WITH DEFAULT KEY,
  tt_sosbom  TYPE STANDARD TABLE OF /ibp/sosbom_ext  WITH DEFAULT KEY,
  tt_sosact  TYPE STANDARD TABLE OF /ibp/sosact_ext  WITH DEFAULT KEY.

*&---------------------------------------------------------------------*
*& Global references shared between the main class and the SPBT
*& ON END OF TASK callback.  The callback must be a FORM (SPBT does not
*& support method callbacks), so the app object must be globally visible.
*&---------------------------------------------------------------------*
CLASS lcl_copy_app DEFINITION DEFERRED.

DATA: go_app       TYPE REF TO lcl_copy_app,   "#EC NEEDED
      gv_in_flight TYPE i.                      "tasks dispatched but not yet returned

*&---------------------------------------------------------------------*
*& Class LCL_COPY_APP
*& Encapsulates all business logic.  The report body and the SPBT
*& callback FORM only delegate to this class.
*&---------------------------------------------------------------------*
CLASS lcl_copy_app DEFINITION.

  PUBLIC SECTION.

    "! Per-table copy statistics accumulated across all parallel tasks.
    TYPES:
      BEGIN OF ty_stat,
        table    TYPE tabname,
        selected TYPE i,   "rows read from source
        inserted TYPE i,   "rows written to target
        deleted  TYPE i,   "pre-existing target rows removed
        failed   TYPE i,   "rows lost due to a task error
      END OF ty_stat,
      ty_stats TYPE STANDARD TABLE OF ty_stat WITH EMPTY KEY.

    METHODS:
      "! Initialise the application with runtime parameters.
      "! @parameter iv_group | RFC server group (must exist in RZ12).
      "! @parameter iv_pkg   | Package size: rows per parallel task.
      "! @parameter iv_npar  | Parallelism cap: max concurrent tasks.
      "! @parameter iv_test  | ABAP_TRUE = count only, no DB writes.
      constructor
        IMPORTING
          iv_group  TYPE spta_rfcgr
          iv_pkg    TYPE i
          iv_npar   TYPE i
          iv_test   TYPE abap_bool,

      "! Orchestrate the full copy run: init -> delete -> copy -> wait.
      run,

      "! Receive the result of one finished parallel task.
      "! Called by the ON END OF TASK FORM; iv_task is the task name
      "! passed by the SPBT framework.
      receive_result
        IMPORTING
          iv_task TYPE clike,

      "! Write a summary report to the SAP list.
      display.

  PRIVATE SECTION.

    CONSTANTS:
      "-- Worker RFC function module name
      c_fm     TYPE rs38l_fnam VALUE 'Z_IBP_PDS_COPY_LOGSYS_PAR',
      "-- Hardcoded source/target logical systems
      c_source TYPE logsys     VALUE 'EDI',
      c_target TYPE logsys     VALUE 'TDS',
      "-- Only rows with this application flag are processed
      c_zzappl TYPE c LENGTH 1 VALUE '1'.

    DATA:
      mv_group    TYPE spta_rfcgr,
      mv_pkg      TYPE i,
      mv_npar     TYPE i,         "max concurrent tasks
      mv_test     TYPE abap_bool,
      mv_max_wp   TYPE i,         "total WPs in the RFC group (from SPBT_INITIALIZE)
      mv_free_wp  TYPE i,         "free WPs at initialisation time
      mv_task_seq TYPE i,         "monotonic counter for unique task names
      mt_stats    TYPE ty_stats.

    METHODS:
      "! Initialise the SPBT parallel framework for mv_group.
      "! Terminates with a type-E message if the group is invalid or
      "! has no free work processes.
      init_rfc_group,

      "! Delete all TDS+ZZAPPL=1 rows from all three tables and commit.
      "! Must run before any inserts to avoid duplicate-key errors,
      "! because LOGSYS is part of every table's primary key.
      delete_target,

      "! Read iv_table's EDI+ZZAPPL=1 rows in packages and dispatch
      "! each package to a parallel worker.
      copy_table
        IMPORTING
          iv_table TYPE tabname,

      "! Thin wrappers: unpack the typed internal table and call
      "! START_TASK with the correct parameter slot.
      dispatch_soshead
        IMPORTING it_data TYPE tt_soshead,
      dispatch_sosbom
        IMPORTING it_data TYPE tt_sosbom,
      dispatch_sosact
        IMPORTING it_data TYPE tt_sosact,

      "! Dispatch one package to the next free work process.
      "! Blocks until a slot is available (WAIT UNTIL gv_in_flight < mv_npar)
      "! and retries on RESOURCE_FAILURE (sy-subrc = 3) until successful.
      start_task
        IMPORTING
          iv_table TYPE tabname
          it_head  TYPE tt_soshead OPTIONAL
          it_bom   TYPE tt_sosbom  OPTIONAL
          it_act   TYPE tt_sosact  OPTIONAL
          iv_rows  TYPE i,

      "! Add counts to the statistics entry for iv_table.
      "! Creates the entry on first call for a given table name.
      add_stat
        IMPORTING
          iv_table    TYPE tabname
          iv_selected TYPE i DEFAULT 0
          iv_inserted TYPE i DEFAULT 0
          iv_deleted  TYPE i DEFAULT 0
          iv_failed   TYPE i DEFAULT 0.

ENDCLASS.


CLASS lcl_copy_app IMPLEMENTATION.

  METHOD constructor.
    mv_group = iv_group.
    mv_pkg   = COND #( WHEN iv_pkg  > 0 THEN iv_pkg  ELSE 100000 ).
    mv_npar  = COND #( WHEN iv_npar > 0 THEN iv_npar ELSE 1 ).
    mv_test  = iv_test.
  ENDMETHOD.


  METHOD run.
    init_rfc_group( ).
    delete_target( ).    "must commit before inserts start

    copy_table( '/IBP/SOSHEAD_EXT' ).
    copy_table( '/IBP/SOSBOM_EXT' ).
    copy_table( '/IBP/SOSACT_EXT' ).

    "Wait for every dispatched task to call back before the caller
    "proceeds to display results.
    WAIT UNTIL gv_in_flight <= 0.
  ENDMETHOD.


  METHOD init_rfc_group.
    "SPBT_INITIALIZE must be called exactly once per program run.
    "It reserves the RFC group and returns how many WPs are available.
    CALL FUNCTION 'SPBT_INITIALIZE'
      EXPORTING
        group_name                     = mv_group
      IMPORTING
        max_pbt_wps                    = mv_max_wp
        free_pbt_wps                   = mv_free_wp
      EXCEPTIONS
        invalid_group_name             = 1
        internal_error                 = 2
        pbt_env_already_initialized    = 3
        currently_no_resources_avail   = 4
        no_pbt_resources_found         = 5
        cant_init_different_pbt_groups = 6
        OTHERS                         = 7.
    IF sy-subrc <> 0.
      MESSAGE ID sy-msgid TYPE 'E' NUMBER sy-msgno
              WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4.
    ENDIF.

    IF mv_free_wp <= 0.
      MESSAGE 'No free work processes available for parallel processing'
              TYPE 'E'.
    ENDIF.
  ENDMETHOD.


  METHOD delete_target.
    DATA lv_del TYPE i.

    "Delete and commit each table individually.  Committing between
    "tables keeps the individual LUW sizes small and makes each
    "deletion visible to workers started for the next table.

    " --- /IBP/SOSHEAD_EXT -----------------------------------------------
    IF mv_test = abap_false.
      DELETE FROM /ibp/soshead_ext
        WHERE logsys = @c_target AND zzappl = @c_zzappl.
      lv_del = sy-dbcnt.
      COMMIT WORK AND WAIT.
    ELSE.
      "Test run: count rows that would be deleted, touch nothing.
      SELECT COUNT(*) FROM /ibp/soshead_ext
        WHERE logsys = @c_target AND zzappl = @c_zzappl INTO @lv_del.
    ENDIF.
    add_stat( iv_table = '/IBP/SOSHEAD_EXT' iv_deleted = lv_del ).

    " --- /IBP/SOSBOM_EXT ------------------------------------------------
    IF mv_test = abap_false.
      DELETE FROM /ibp/sosbom_ext
        WHERE logsys = @c_target AND zzappl = @c_zzappl.
      lv_del = sy-dbcnt.
      COMMIT WORK AND WAIT.
    ELSE.
      SELECT COUNT(*) FROM /ibp/sosbom_ext
        WHERE logsys = @c_target AND zzappl = @c_zzappl INTO @lv_del.
    ENDIF.
    add_stat( iv_table = '/IBP/SOSBOM_EXT' iv_deleted = lv_del ).

    " --- /IBP/SOSACT_EXT ------------------------------------------------
    IF mv_test = abap_false.
      DELETE FROM /ibp/sosact_ext
        WHERE logsys = @c_target AND zzappl = @c_zzappl.
      lv_del = sy-dbcnt.
      COMMIT WORK AND WAIT.
    ELSE.
      SELECT COUNT(*) FROM /ibp/sosact_ext
        WHERE logsys = @c_target AND zzappl = @c_zzappl INTO @lv_del.
    ENDIF.
    add_stat( iv_table = '/IBP/SOSACT_EXT' iv_deleted = lv_del ).
  ENDMETHOD.


  METHOD copy_table.
    "Two-pass design to avoid dump 'Cursor already closed':
    "  WAIT UNTIL (inside start_task) causes the ABAP runtime to process
    "  queued events, which closes any open DB cursor.  Dispatching inside
    "  SELECT...ENDSELECT therefore triggers this dump under parallel load.
    "Pass 1 - read all packages into memory (no WAIT, cursor stays open).
    "Pass 2 - dispatch each collected package (WAIT is safe; cursor closed).

    CASE iv_table.

      WHEN '/IBP/SOSHEAD_EXT'.
        TYPES tt_pkgs_head TYPE TABLE OF tt_soshead WITH DEFAULT KEY.
        DATA: lt_pkgs_head TYPE tt_pkgs_head,
              lt_head      TYPE tt_soshead.
        "Pass 1: collect
        SELECT * FROM /ibp/soshead_ext
          WHERE logsys = @c_source AND zzappl = @c_zzappl
          INTO TABLE @lt_head PACKAGE SIZE @mv_pkg.
          add_stat( iv_table = iv_table iv_selected = lines( lt_head ) ).
          APPEND lt_head TO lt_pkgs_head.
        ENDSELECT.
        "Pass 2: dispatch (cursor is now closed)
        LOOP AT lt_pkgs_head INTO lt_head.
          dispatch_soshead( lt_head ).
        ENDLOOP.

      WHEN '/IBP/SOSBOM_EXT'.
        TYPES tt_pkgs_bom TYPE TABLE OF tt_sosbom WITH DEFAULT KEY.
        DATA: lt_pkgs_bom TYPE tt_pkgs_bom,
              lt_bom      TYPE tt_sosbom.
        "Pass 1: collect
        SELECT * FROM /ibp/sosbom_ext
          WHERE logsys = @c_source AND zzappl = @c_zzappl
          INTO TABLE @lt_bom PACKAGE SIZE @mv_pkg.
          add_stat( iv_table = iv_table iv_selected = lines( lt_bom ) ).
          APPEND lt_bom TO lt_pkgs_bom.
        ENDSELECT.
        "Pass 2: dispatch (cursor is now closed)
        LOOP AT lt_pkgs_bom INTO lt_bom.
          dispatch_sosbom( lt_bom ).
        ENDLOOP.

      WHEN '/IBP/SOSACT_EXT'.
        TYPES tt_pkgs_act TYPE TABLE OF tt_sosact WITH DEFAULT KEY.
        DATA: lt_pkgs_act TYPE tt_pkgs_act,
              lt_act      TYPE tt_sosact.
        "Pass 1: collect
        SELECT * FROM /ibp/sosact_ext
          WHERE logsys = @c_source AND zzappl = @c_zzappl
          INTO TABLE @lt_act PACKAGE SIZE @mv_pkg.
          add_stat( iv_table = iv_table iv_selected = lines( lt_act ) ).
          APPEND lt_act TO lt_pkgs_act.
        ENDSELECT.
        "Pass 2: dispatch (cursor is now closed)
        LOOP AT lt_pkgs_act INTO lt_act.
          dispatch_sosact( lt_act ).
        ENDLOOP.

    ENDCASE.
  ENDMETHOD.


  "The three dispatch methods exist because CALL FUNCTION ... TABLES
  "uses positional matching; passing data via the correct parameter
  "slot avoids sending empty tables across the RFC boundary unnecessarily.

  METHOD dispatch_soshead.
    start_task( iv_table = '/IBP/SOSHEAD_EXT'
                it_head  = it_data
                iv_rows  = lines( it_data ) ).
  ENDMETHOD.

  METHOD dispatch_sosbom.
    start_task( iv_table = '/IBP/SOSBOM_EXT'
                it_bom   = it_data
                iv_rows  = lines( it_data ) ).
  ENDMETHOD.

  METHOD dispatch_sosact.
    start_task( iv_table = '/IBP/SOSACT_EXT'
                it_act   = it_data
                iv_rows  = lines( it_data ) ).
  ENDMETHOD.


  METHOD start_task.
    DATA lv_task TYPE char32.

    IF iv_rows = 0.
      RETURN.   "empty package - nothing to dispatch
    ENDIF.

    IF mv_test = abap_true.
      "Test run: simulate the insert count without touching the DB.
      add_stat( iv_table = iv_table iv_inserted = iv_rows ).
      RETURN.
    ENDIF.

    "Throttle: block until the number of in-flight tasks drops below
    "the configured cap before starting a new one.
    WAIT UNTIL gv_in_flight < mv_npar UP TO 60 SECONDS.

    mv_task_seq = mv_task_seq + 1.
    lv_task     = |{ iv_table }_{ mv_task_seq }|.   "unique task name

    DO.   "retry loop: handle transient resource shortages
      CALL FUNCTION c_fm
        STARTING NEW TASK lv_task
        DESTINATION IN GROUP mv_group
        PERFORMING on_end_of_task ON END OF TASK
        EXPORTING
          iv_source_logsys      = c_source
          iv_target_logsys      = c_target
          iv_table              = iv_table
        TABLES
          it_soshead            = it_head
          it_sosbom             = it_bom
          it_sosact             = it_act
        EXCEPTIONS
          communication_failure = 1
          system_failure        = 2
          resource_failure      = 3
          OTHERS                = 4.

      CASE sy-subrc.
        WHEN 0.
          gv_in_flight = gv_in_flight + 1.
          EXIT.                               "dispatched successfully
        WHEN 3.
          "RESOURCE_FAILURE means all WPs in the group are busy.
          "Wait for a slot to free up, then retry the same package.
          WAIT UNTIL gv_in_flight < mv_npar UP TO 5 SECONDS.
        WHEN OTHERS.
          "COMMUNICATION_FAILURE or SYSTEM_FAILURE: unrecoverable for
          "this package; record the loss and move on.
          add_stat( iv_table = iv_table iv_failed = iv_rows ).
          EXIT.
      ENDCASE.
    ENDDO.
  ENDMETHOD.


  METHOD receive_result.
    "Called by FORM ON_END_OF_TASK when a worker finishes.
    "RECEIVE RESULTS retrieves the exported parameters and any
    "exception raised inside the remote function module.
    DATA: lv_inserted TYPE i,
          lv_table    TYPE tabname.

    RECEIVE RESULTS FROM FUNCTION c_fm
      IMPORTING
        ev_inserted           = lv_inserted
        ev_table              = lv_table
      EXCEPTIONS
        insert_failed         = 1
        communication_failure = 2
        system_failure        = 3
        OTHERS                = 4.

    IF sy-subrc = 0.
      add_stat( iv_table = lv_table iv_inserted = lv_inserted ).
    ELSE.
      "Worker raised INSERT_FAILED or a communication error occurred;
      "count 1 failed task (exact row count not recoverable here).
      add_stat( iv_table = lv_table iv_failed = 1 ).
    ENDIF.

    gv_in_flight = gv_in_flight - 1.   "release the slot
  ENDMETHOD.


  METHOD add_stat.
    "Locate or create the statistics row for the given table and
    "accumulate the supplied deltas into it.
    ASSIGN mt_stats[ table = iv_table ] TO FIELD-SYMBOL(<s>).
    IF sy-subrc <> 0.
      APPEND VALUE #( table = iv_table ) TO mt_stats ASSIGNING <s>.
    ENDIF.
    <s>-selected = <s>-selected + iv_selected.
    <s>-inserted = <s>-inserted + iv_inserted.
    <s>-deleted  = <s>-deleted  + iv_deleted.
    <s>-failed   = <s>-failed   + iv_failed.
  ENDMETHOD.


  METHOD display.
    WRITE: / 'PDS LOGSYS copy', c_source, '->', c_target,
             '  (ZZAPPL =', c_zzappl, ')'.
    IF mv_test = abap_true.
      WRITE: '(TEST RUN - no database changes)'.
    ENDIF.
    ULINE.
    FORMAT COLOR COL_HEADING.
    WRITE: /(20) 'Table', (12) 'Selected', (12) 'Inserted',
            (12) 'Deleted', (12) 'Failed'.
    FORMAT COLOR OFF.
    LOOP AT mt_stats ASSIGNING FIELD-SYMBOL(<s>).
      WRITE: /(20) <s>-table, (12) <s>-selected, (12) <s>-inserted,
              (12) <s>-deleted, (12) <s>-failed.
    ENDLOOP.
    ULINE.
  ENDMETHOD.

ENDCLASS.



*&---------------------------------------------------------------------*
*& FORM ON_END_OF_TASK
*& SPBT ON END OF TASK callback.  The SPBT framework requires a
*& subroutine here - method callbacks are not supported.  This FORM
*& simply delegates to the application object so that all logic stays
*& inside the class.
*&---------------------------------------------------------------------*
FORM on_end_of_task USING p_task TYPE clike.
  go_app->receive_result( p_task ).
ENDFORM.


*&---------------------------------------------------------------------*
*& AT SELECTION-SCREEN events
*&---------------------------------------------------------------------*


*&---------------------------------------------------------------------*
*& START-OF-SELECTION
*&---------------------------------------------------------------------*
START-OF-SELECTION.
  "Source and target logical systems are hardcoded (EDI -> TDS).
  "Only rows with ZZAPPL = '1' are processed.
  IF p_npar <= 0.
    MESSAGE 'Number of parallel processes must be at least 1' TYPE 'E'.
  ENDIF.

  go_app = NEW lcl_copy_app( iv_group  = p_group
                             iv_pkg    = p_pkg
                             iv_npar   = p_npar
                             iv_test   = p_test ).
  go_app->run( ).

END-OF-SELECTION.
  go_app->display( ).

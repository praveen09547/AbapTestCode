*&---------------------------------------------------------------------*
*& Report ZIBP_PDS_COPY_LOGSYS
*&---------------------------------------------------------------------*
*& Purpose : Copy IBP source-of-supply (PDS) data from logical system
*&           EDI to TDS.  Reads records from
*&                 /IBP/SOSHEAD_EXT
*&                 /IBP/SOSBOM_EXT
*&                 /IBP/SOSACT_EXT
*&           and creates copies carrying LOGSYS = 'TDS'.
*&
*&           Existing TDS records are deleted first, then copies are
*&           inserted.  Insertion is distributed across work processes
*&           using the SPBT parallel processing framework.
*&
*& Note    : LOGSYS is part of the primary key of all three tables, so a
*&           source row and its copy have different keys - flipping
*&           LOGSYS and inserting therefore produces no key clash once
*&           the stale target rows have been removed.
*&---------------------------------------------------------------------*
REPORT zibp_pds_copy_logsys.

*&---------------------------------------------------------------------*
*& Selection screen
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-b01.
PARAMETERS:
  p_group TYPE rzlli_apcl      DEFAULT 'parallel_generators',
  p_pkg   TYPE i               DEFAULT 100000,
  p_npar  TYPE i               DEFAULT 1,
  p_test  TYPE abap_bool AS CHECKBOX.
SELECTION-SCREEN END OF BLOCK b1.

*&---------------------------------------------------------------------*
*& F4 help for RFC server group - reads live values from table RZLLI
*&---------------------------------------------------------------------*
AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_group.
  PERFORM f4_rfc_group CHANGING p_group.

*&---------------------------------------------------------------------*
*& Table types over the DB structures (IBP does not necessarily deliver
*& ready-made table types, so define our own for the RFC payloads).
*&---------------------------------------------------------------------*
TYPES:
  tt_soshead TYPE STANDARD TABLE OF /ibp/soshead_ext WITH DEFAULT KEY,
  tt_sosbom  TYPE STANDARD TABLE OF /ibp/sosbom_ext  WITH DEFAULT KEY,
  tt_sosact  TYPE STANDARD TABLE OF /ibp/sosact_ext  WITH DEFAULT KEY.

*&---------------------------------------------------------------------*
*& Global data used by the ON END OF TASK callback (FORM required by
*& the SPBT framework - method callbacks are not supported there).
*&---------------------------------------------------------------------*
CLASS lcl_copy_app DEFINITION DEFERRED.

DATA: go_app       TYPE REF TO lcl_copy_app,       "#EC NEEDED
      gv_in_flight TYPE i.                          "tasks still running

*&---------------------------------------------------------------------*
*& Local class - all business logic lives here, the report body and the
*& callback FORM only delegate to it.
*&---------------------------------------------------------------------*
CLASS lcl_copy_app DEFINITION.

  PUBLIC SECTION.
    TYPES:
      BEGIN OF ty_stat,
        table    TYPE tabname,
        selected TYPE i,
        inserted TYPE i,
        deleted  TYPE i,
        failed   TYPE i,
      END OF ty_stat,
      ty_stats TYPE STANDARD TABLE OF ty_stat WITH EMPTY KEY.

    METHODS:
      constructor
        IMPORTING
          iv_group  TYPE rzlli_apcl
          iv_pkg    TYPE i
          iv_npar   TYPE i
          iv_test   TYPE abap_bool,
      run,
      "! Called back (via FORM) when a parallel task finishes.
      receive_result
        IMPORTING
          iv_task TYPE clike,
      display.

  PRIVATE SECTION.
    CONSTANTS:
      c_fm     TYPE rs38l_fnam VALUE 'Z_IBP_PDS_COPY_LOGSYS_PAR',
      c_source TYPE logsys     VALUE 'EDI',
      c_target TYPE logsys     VALUE 'TDS'.

    DATA:
      mv_group    TYPE rzlli_apcl,
      mv_pkg      TYPE i,
      mv_npar     TYPE i,
      mv_test     TYPE abap_bool,
      mv_max_wp   TYPE i,
      mv_free_wp  TYPE i,
      mv_task_seq TYPE i,
      mt_stats    TYPE ty_stats.

    METHODS:
      init_rfc_group,
      delete_target,
      copy_table
        IMPORTING
          iv_table TYPE tabname,
      dispatch_soshead
        IMPORTING it_data TYPE tt_soshead,
      dispatch_sosbom
        IMPORTING it_data TYPE tt_sosbom,
      dispatch_sosact
        IMPORTING it_data TYPE tt_sosact,
      start_task
        IMPORTING
          iv_table TYPE tabname
          it_head  TYPE tt_soshead OPTIONAL
          it_bom   TYPE tt_sosbom  OPTIONAL
          it_act   TYPE tt_sosact  OPTIONAL
          iv_rows  TYPE i,
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
    mv_group  = iv_group.
    mv_pkg    = COND #( WHEN iv_pkg  > 0 THEN iv_pkg  ELSE 100000 ).
    mv_npar   = COND #( WHEN iv_npar > 0 THEN iv_npar ELSE 1 ).
    mv_test   = iv_test.
  ENDMETHOD.

  METHOD run.
    init_rfc_group( ).
    delete_target( ).

    copy_table( '/IBP/SOSHEAD_EXT' ).
    copy_table( '/IBP/SOSBOM_EXT' ).
    copy_table( '/IBP/SOSACT_EXT' ).

    " Wait for every dispatched task to report back.
    WAIT UNTIL gv_in_flight <= 0.
  ENDMETHOD.

  METHOD init_rfc_group.
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

    " SOSHEAD ------------------------------------------------------------
    IF mv_test = abap_false.
      DELETE FROM /ibp/soshead_ext WHERE logsys = @c_target.
      lv_del = sy-dbcnt.
      COMMIT WORK AND WAIT.
    ELSE.
      SELECT COUNT(*) FROM /ibp/soshead_ext
        WHERE logsys = @c_target INTO @lv_del.
    ENDIF.
    add_stat( iv_table = '/IBP/SOSHEAD_EXT' iv_deleted = lv_del ).

    " SOSBOM -------------------------------------------------------------
    IF mv_test = abap_false.
      DELETE FROM /ibp/sosbom_ext WHERE logsys = @c_target.
      lv_del = sy-dbcnt.
      COMMIT WORK AND WAIT.
    ELSE.
      SELECT COUNT(*) FROM /ibp/sosbom_ext
        WHERE logsys = @c_target INTO @lv_del.
    ENDIF.
    add_stat( iv_table = '/IBP/SOSBOM_EXT' iv_deleted = lv_del ).

    " SOSACT -------------------------------------------------------------
    IF mv_test = abap_false.
      DELETE FROM /ibp/sosact_ext WHERE logsys = @c_target.
      lv_del = sy-dbcnt.
      COMMIT WORK AND WAIT.
    ELSE.
      SELECT COUNT(*) FROM /ibp/sosact_ext
        WHERE logsys = @c_target INTO @lv_del.
    ENDIF.
    add_stat( iv_table = '/IBP/SOSACT_EXT' iv_deleted = lv_del ).
  ENDMETHOD.

  METHOD copy_table.
    " Read the source rows in packages and hand each package to a free
    " work process.  Reading in packages keeps the amount of data moved
    " across the RFC boundary bounded.
    CASE iv_table.

      WHEN '/IBP/SOSHEAD_EXT'.
        DATA lt_head TYPE tt_soshead.
        SELECT * FROM /ibp/soshead_ext
          WHERE logsys = @c_source
          INTO TABLE @lt_head PACKAGE SIZE @mv_pkg.
          add_stat( iv_table = iv_table iv_selected = lines( lt_head ) ).
          dispatch_soshead( lt_head ).
        ENDSELECT.

      WHEN '/IBP/SOSBOM_EXT'.
        DATA lt_bom TYPE tt_sosbom.
        SELECT * FROM /ibp/sosbom_ext
          WHERE logsys = @c_source
          INTO TABLE @lt_bom PACKAGE SIZE @mv_pkg.
          add_stat( iv_table = iv_table iv_selected = lines( lt_bom ) ).
          dispatch_sosbom( lt_bom ).
        ENDSELECT.

      WHEN '/IBP/SOSACT_EXT'.
        DATA lt_act TYPE tt_sosact.
        SELECT * FROM /ibp/sosact_ext
          WHERE logsys = @c_source
          INTO TABLE @lt_act PACKAGE SIZE @mv_pkg.
          add_stat( iv_table = iv_table iv_selected = lines( lt_act ) ).
          dispatch_sosact( lt_act ).
        ENDSELECT.

    ENDCASE.
  ENDMETHOD.

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
      RETURN.
    ENDIF.

    IF mv_test = abap_true.
      " Test run: count only, do not spawn a task or write to the DB.
      add_stat( iv_table = iv_table iv_inserted = iv_rows ).
      RETURN.
    ENDIF.

    " Honour the configured parallelism cap before dispatching.
    WAIT UNTIL gv_in_flight < mv_npar UP TO 60 SECONDS.

    mv_task_seq = mv_task_seq + 1.
    lv_task     = |{ iv_table }_{ mv_task_seq }|.

    DO.
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
          EXIT.                                   "dispatched, leave DO
        WHEN 3.
          " No free work process right now - let running tasks drain,
          " then retry this package.
          WAIT UNTIL gv_in_flight < mv_npar UP TO 5 SECONDS.
        WHEN OTHERS.
          add_stat( iv_table = iv_table iv_failed = iv_rows ).
          EXIT.
      ENDCASE.
    ENDDO.
  ENDMETHOD.

  METHOD receive_result.
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
      add_stat( iv_table = lv_table iv_failed = 1 ).
    ENDIF.

    gv_in_flight = gv_in_flight - 1.
  ENDMETHOD.

  METHOD add_stat.
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
    WRITE: / 'PDS LOGSYS copy', c_source, '->', c_target.
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
*& F4 for RFC server group - reads distinct group names from RZLLI
*&---------------------------------------------------------------------*
FORM f4_rfc_group CHANGING cv_group TYPE rzlli_apcl.
  TYPES: BEGIN OF ty_grp,
           apcl TYPE rzlli-apcl,
         END OF ty_grp.
  DATA: lt_grp TYPE TABLE OF ty_grp,
        lt_ret TYPE TABLE OF ddshretval.

  SELECT DISTINCT apcl FROM rzlli INTO TABLE @lt_grp ORDER BY apcl.

  CALL FUNCTION 'F4IF_INT_TABLE_VALUE_REQUEST'
    EXPORTING
      retfield        = 'APCL'
      dynpprog        = sy-repid
      dynpnr          = sy-dynnr
      dynpfld         = 'P_GROUP'
      value_org       = 'S'
    TABLES
      value_tab       = lt_grp
      return_tab      = lt_ret
    EXCEPTIONS
      parameter_error = 1
      no_values_found = 2
      OTHERS          = 3.

  IF sy-subrc = 0 AND lt_ret IS NOT INITIAL.
    cv_group = lt_ret[ 1 ]-fieldval.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& ON END OF TASK callback - SPBT requires a subroutine here.
*&---------------------------------------------------------------------*
FORM on_end_of_task USING p_task TYPE clike.
  go_app->receive_result( p_task ).
ENDFORM.

*&---------------------------------------------------------------------*
*& Main
*&---------------------------------------------------------------------*
START-OF-SELECTION.
  go_app = NEW lcl_copy_app( iv_group  = p_group
                             iv_pkg    = p_pkg
                             iv_npar   = p_npar
                             iv_test   = p_test ).
  go_app->run( ).

END-OF-SELECTION.
  go_app->display( ).

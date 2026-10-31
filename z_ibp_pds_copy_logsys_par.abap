FUNCTION z_ibp_pds_copy_logsys_par.
*"----------------------------------------------------------------------
*" Remote-Enabled Module (RFC)  -  processing type: "Remote"
*"
*" Worker called by report ZIBP_PDS_COPY_LOGSYS via the SPBT parallel
*" processing framework.  Each invocation receives one package of rows
*" belonging to exactly one IBP sourcing table, overwrites their LOGSYS
*" field with the target value, and bulk-inserts the copies.
*"
*" Each parallel task runs in its own work process and therefore its
*" own LUW.  The final COMMIT WORK AND WAIT makes the inserts durable
*" before control returns to the dispatcher.
*"
*" Only one of IT_SOSHEAD / IT_SOSBOM / IT_SOSACT will be populated per
*" call; the other two are declared OPTIONAL so the framework does not
*" transfer empty tables across the RFC boundary unnecessarily.
*"
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_SOURCE_LOGSYS) TYPE  LOGSYS
*"     VALUE(IV_TARGET_LOGSYS) TYPE  LOGSYS
*"     VALUE(IV_TABLE) TYPE  TABNAME
*"  EXPORTING
*"     VALUE(EV_INSERTED) TYPE  I
*"     VALUE(EV_TABLE) TYPE  TABNAME
*"  TABLES
*"      IT_SOSHEAD STRUCTURE  /IBP/SOSHEAD_EXT OPTIONAL
*"      IT_SOSBOM STRUCTURE  /IBP/SOSBOM_EXT OPTIONAL
*"      IT_SOSACT STRUCTURE  /IBP/SOSACT_EXT OPTIONAL
*"  EXCEPTIONS
*"      INSERT_FAILED
*"----------------------------------------------------------------------

  "Echo the table name back so the dispatcher can route the result
  "to the correct statistics counter without needing to parse the task name.
  ev_table    = iv_table.
  ev_inserted = 0.

  CASE iv_table.

    WHEN '/IBP/SOSHEAD_EXT'.
      "Overwrite LOGSYS on every row in the package.
      "The field-symbol loop avoids copying each row; changes are in-place.
      LOOP AT it_soshead ASSIGNING FIELD-SYMBOL(<head>).
        <head>-logsys = iv_target_logsys.
      ENDLOOP.

      IF it_soshead[] IS NOT INITIAL.
        "Bulk insert: a single INSERT ... FROM TABLE is faster than
        "row-by-row inserts and holds fewer locks.
        INSERT /ibp/soshead_ext FROM TABLE it_soshead[].
        IF sy-subrc <> 0.
          "Duplicate key or DB error: roll back this LUW and signal
          "the dispatcher that the package was lost.
          ROLLBACK WORK.
          RAISE insert_failed.
        ENDIF.
        ev_inserted = lines( it_soshead[] ).
      ENDIF.

    WHEN '/IBP/SOSBOM_EXT'.
      LOOP AT it_sosbom ASSIGNING FIELD-SYMBOL(<bom>).
        <bom>-logsys = iv_target_logsys.
      ENDLOOP.

      IF it_sosbom[] IS NOT INITIAL.
        INSERT /ibp/sosbom_ext FROM TABLE it_sosbom[].
        IF sy-subrc <> 0.
          ROLLBACK WORK.
          RAISE insert_failed.
        ENDIF.
        ev_inserted = lines( it_sosbom[] ).
      ENDIF.

    WHEN '/IBP/SOSACT_EXT'.
      LOOP AT it_sosact ASSIGNING FIELD-SYMBOL(<act>).
        <act>-logsys = iv_target_logsys.
      ENDLOOP.

      IF it_sosact[] IS NOT INITIAL.
        INSERT /ibp/sosact_ext FROM TABLE it_sosact[].
        IF sy-subrc <> 0.
          ROLLBACK WORK.
          RAISE insert_failed.
        ENDIF.
        ev_inserted = lines( it_sosact[] ).
      ENDIF.

  ENDCASE.

  "Commit this task's LUW before returning to the dispatcher.
  "AND WAIT ensures the data is visible on the database before the
  "dispatcher's RECEIVE RESULTS processes EV_INSERTED.
  COMMIT WORK AND WAIT.

ENDFUNCTION.

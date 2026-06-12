from django.contrib import admin
from import_export.admin import ImportExportActionModelAdmin

from user.models import DataType, MessageStructure
from user.resources import DataTypeResource, MessageStructureResource

# Register your models here.

class DataTypeAdmin(ImportExportActionModelAdmin):
    resource_classes = [DataTypeResource]

    list_display = [
        'name',
        'ui_component',
        'meta_kwargs'
    ]

class MessageStructureAdmin(ImportExportActionModelAdmin):
    resource_classes = [MessageStructureResource]
    list_display = [
        'sequence',
        'parent_sequence__sequence',
        'code',
        'label',
        'data_type__name',
        'min_occurs',
        'max_occurs',
        'version'
    ]


admin.site.register(DataType, DataTypeAdmin)
admin.site.register(MessageStructure, MessageStructureAdmin)
use sea_orm::entity::prelude::*;

#[derive(Clone, Debug, PartialEq, DeriveEntityModel)]
#[sea_orm(table_name = "installations")]
pub struct Model {
    #[sea_orm(primary_key, auto_increment = false)]
    pub id: Uuid,
    pub app_attest_key_id: String,
    pub public_key: Vec<u8>,
    pub environment: String,
    pub status: String,
    pub sign_count: i64,
    pub created_at: DateTimeUtc,
    pub updated_at: DateTimeUtc,
    pub last_seen_at: Option<DateTimeUtc>,
}

#[derive(Copy, Clone, Debug, EnumIter, DeriveRelation)]
pub enum Relation {
    #[sea_orm(has_many = "super::challenge::Entity")]
    Challenges,
}

impl Related<super::challenge::Entity> for Entity {
    fn to() -> RelationDef {
        Relation::Challenges.def()
    }
}

impl ActiveModelBehavior for ActiveModel {}

use std::{fmt::Debug, future::Future, io, path::PathBuf};
use tokio::{fs, io::AsyncWriteExt, sync::oneshot, task::JoinError};
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum Failure<E> {
    #[error("fixture creation: {0}")]
    Create(io::Error),
    #[error("fixture write: {0}")]
    Write(io::Error),
    #[error("fixture operation: {0}")]
    Operation(E),
    #[error("fixture task: {0}")]
    Task(JoinError),
}

#[derive(Debug)]
pub struct Outcome<T, E> {
    pub operation: Result<T, Failure<E>>,
    pub cleanup: io::Result<()>,
}

impl<T, E: Debug> Outcome<T, E> {
    pub fn finish(self) -> T {
        // Report both causes before resuming an original panic payload.
        if let Err(error) = &self.cleanup {
            eprintln!(
                "signing fixture cleanup failed: {error}; operation failure: {:?}",
                self.operation.as_ref().err()
            );
        }
        let operation = match self.operation {
            Err(Failure::Task(error)) if error.is_panic() => {
                std::panic::resume_unwind(error.into_panic())
            }
            outcome => outcome,
        };
        self.cleanup.expect("signing fixture cleanup must succeed");
        operation.expect("signing fixture operation must succeed")
    }
}

pub fn unique_path() -> PathBuf {
    std::env::temp_dir().join(format!("bleat-test-jwt-{}.der", Uuid::new_v4()))
}

/// The caller must await this lifecycle to completion. Cancellation is requested
/// through `cancel`, never by dropping/aborting this future. Creation and writes
/// finish before cancellation is observed; the operation is then aborted and
/// joined before checked removal. Runtime destruction/process kill are excluded.
/// The operation must not start unjoined filesystem work of its own.
pub async fn run<T, E, F, Fut>(
    path: PathBuf,
    bytes: Vec<u8>,
    mut cancel: oneshot::Receiver<()>,
    operation: F,
) -> Outcome<T, E>
where
    T: Send + 'static,
    E: Send + 'static,
    F: FnOnce(PathBuf) -> Fut + Send + 'static,
    Fut: Future<Output = Result<T, E>> + Send + 'static,
{
    // Exclusive creation establishes ownership without ever truncating or
    // deleting an existing path, even in the unlikely event of a UUID collision.
    let mut file = match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .await
    {
        Ok(file) => file,
        Err(error) => {
            return Outcome {
                operation: Err(Failure::Create(error)),
                cleanup: Ok(()),
            };
        }
    };
    let written = file.write_all(&bytes).await;
    // Tokio writes may still be in flight after write_all; flush before closing
    // and before any cancellation/removal or router read.
    let written = match written {
        Ok(()) => file.flush().await,
        Err(error) => {
            let _ = file.flush().await;
            Err(error)
        }
    };
    drop(file);
    let result = match written {
        Err(error) => Err(Failure::Write(error)),
        Ok(()) => {
            // Invoke the closure inside the task so construction panics, async
            // panics and assertion unwinding all reach the same cleanup path.
            let operation_path = path.clone();
            let mut task = tokio::spawn(async move { operation(operation_path).await });
            let joined = tokio::select! {
                result = &mut task => result,
                _ = &mut cancel => { task.abort(); task.await }
            };
            match joined {
                Ok(result) => result.map_err(Failure::Operation),
                Err(error) => Err(Failure::Task(error)),
            }
        }
    };
    Outcome {
        operation: result,
        cleanup: fs::remove_file(&path).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::convert::Infallible;
    use tokio::time::{Duration, timeout};

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum Stage {
        Configuration,
        Database,
        Router,
    }

    async fn absent(path: &PathBuf) {
        assert_eq!(
            fs::metadata(path)
                .await
                .expect_err("fixture must be removed")
                .kind(),
            io::ErrorKind::NotFound
        );
    }

    async fn stage_failure(stage: Stage) {
        let path = unique_path();
        let observed = path.clone();
        let (_cancel, cancelled) = oneshot::channel();
        let outcome = run(
            path.clone(),
            b"test key".to_vec(),
            cancelled,
            move |created| async move {
                assert_eq!(created, observed);
                assert_eq!(
                    fs::read(created).await.expect("fixture should exist"),
                    b"test key"
                );
                Err::<(), _>(stage)
            },
        )
        .await;
        outcome.cleanup.expect("cleanup should succeed");
        let Err(Failure::Operation(original)) = outcome.operation else {
            panic!("stage failure must survive")
        };
        absent(&path).await;
        // Return the exact typed stage, rather than reconstructing it from text.
        assert_eq!(original, stage);
    }

    #[tokio::test]
    async fn configuration_failure_cleans_fixture() {
        stage_failure(Stage::Configuration).await;
    }
    #[tokio::test]
    async fn database_failure_cleans_fixture() {
        stage_failure(Stage::Database).await;
    }
    #[tokio::test]
    async fn router_failure_cleans_fixture() {
        stage_failure(Stage::Router).await;
    }

    #[tokio::test]
    async fn success_and_unexpected_success_clean_before_assertion() {
        for value in [false, true] {
            let path = unique_path();
            let (_cancel, cancelled) = oneshot::channel();
            let outcome = run(path.clone(), vec![1], cancelled, move |_| async move {
                Ok::<_, Infallible>(value)
            })
            .await;
            absent(&path).await;
            assert_eq!(outcome.finish(), value);
        }
    }

    #[tokio::test]
    async fn cancellation_joins_operation_then_cleans_fixture() {
        let path = unique_path();
        let (cancel, cancelled) = oneshot::channel();
        let (entered, ready) = oneshot::channel();
        let owner_path = path.clone();
        let owner = tokio::spawn(run(owner_path, vec![1], cancelled, move |_| async move {
            entered.send(()).expect("owner should observe creation");
            std::future::pending::<Result<(), Infallible>>().await
        }));
        // Five seconds is a deadlock diagnostic budget, not a completion delay.
        let ready = timeout(Duration::from_secs(5), ready).await;
        let _ = cancel.send(());
        let outcome = owner.await.expect("lifecycle should finish");
        outcome.cleanup.expect("cleanup should succeed");
        absent(&path).await;
        ready
            .expect("operation should reach controlled suspension")
            .expect("creation signal should arrive");
        assert!(matches!(outcome.operation, Err(Failure::Task(error)) if error.is_cancelled()));
    }

    #[tokio::test]
    async fn unwinding_retains_original_payload_after_cleanup() {
        let path = unique_path();
        let (_cancel, cancelled) = oneshot::channel();
        let outcome = run(path.clone(), vec![1], cancelled, |_| async {
            std::panic::panic_any(Stage::Router);
            #[allow(unreachable_code)]
            Ok::<(), Infallible>(())
        })
        .await;
        absent(&path).await;
        let resumed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| outcome.finish()))
            .expect_err("original panic should resume");
        assert_eq!(
            *resumed
                .downcast::<Stage>()
                .expect("typed panic payload must survive"),
            Stage::Router
        );
    }

    async fn cleanup_failure(fail_operation: bool) {
        let path = unique_path();
        let (_cancel, cancelled) = oneshot::channel();
        let outcome = run(
            path.clone(),
            vec![1],
            cancelled,
            move |created| async move {
                fs::remove_file(&created)
                    .await
                    .expect("owned file should exist");
                fs::create_dir(&created)
                    .await
                    .expect("inject remove_file failure");
                if fail_operation {
                    Err(Stage::Database)
                } else {
                    Ok(())
                }
            },
        )
        .await;
        fs::remove_dir(&path)
            .await
            .expect("remove owned fault injection directory");
        assert!(
            outcome.cleanup.is_err(),
            "cleanup failure must be observable"
        );
        if fail_operation {
            assert!(matches!(
                outcome.operation,
                Err(Failure::Operation(Stage::Database))
            ));
        } else {
            assert!(outcome.operation.is_ok());
        }
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| outcome.finish())).is_err(),
            "cleanup failure must fail even successful work"
        );
    }

    #[tokio::test]
    async fn cleanup_failure_fails_successful_work() {
        cleanup_failure(false).await;
    }
    #[tokio::test]
    async fn cleanup_failure_preserves_operation_failure() {
        cleanup_failure(true).await;
    }

    #[tokio::test]
    async fn instances_and_existing_sentinel_are_isolated() {
        let sentinel = unique_path();
        fs::write(&sentinel, b"sentinel")
            .await
            .expect("create unrelated sentinel");
        let first = unique_path();
        let second = unique_path();
        let (_cancel, cancelled) = oneshot::channel();
        let other = second.clone();
        let sentinel_copy = sentinel.clone();
        let first_copy = first.clone();
        let outcome = run(first.clone(), vec![1], cancelled, move |_| async move {
            let (_cancel, cancelled) = oneshot::channel();
            let result = run(other.clone(), vec![2], cancelled, move |_| async move {
                Ok::<_, Infallible>(())
            })
            .await;
            result.finish();
            absent(&other).await;
            assert_eq!(
                fs::read(first_copy).await.expect("first still owned"),
                vec![1]
            );
            assert_eq!(
                fs::read(sentinel_copy).await.expect("sentinel untouched"),
                b"sentinel"
            );
            Ok::<_, Infallible>(())
        })
        .await;
        let (_cancel, cancelled) = oneshot::channel();
        let collision = run(sentinel.clone(), vec![9], cancelled, |_| async {
            Ok::<_, Infallible>(())
        })
        .await;
        let sentinel_bytes = fs::read(&sentinel).await;
        fs::remove_file(&sentinel)
            .await
            .expect("sentinel owner cleans up");
        outcome.finish();
        absent(&first).await;
        assert_ne!(first, second);
        assert!(
            matches!(collision.operation, Err(Failure::Create(error)) if error.kind() == io::ErrorKind::AlreadyExists)
        );
        collision.cleanup.expect("unowned path requires no cleanup");
        assert_eq!(
            sentinel_bytes.expect("sentinel preserved on collision"),
            b"sentinel"
        );
    }
}

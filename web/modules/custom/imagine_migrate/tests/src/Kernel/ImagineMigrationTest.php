<?php

declare(strict_types=1);

namespace Drupal\Tests\imagine_migrate\Kernel;

use Drupal\Core\Config\FileStorage;
use Drupal\KernelTests\KernelTestBase;
use Drupal\migrate\MigrateExecutable;
use Drupal\migrate\MigrateMessage;
use Drupal\migrate\Plugin\MigrateIdMapInterface;
use Drupal\node\NodeInterface;

/**
 * Runs the Imagine migrations against the fixture content.
 *
 * The content model is not duplicated for the test: setUp() loads the real
 * exported config from config/sync, so the test also proves that config
 * matches what the migrations write to.
 *
 * @group imagine_migrate
 */
final class ImagineMigrationTest extends KernelTestBase {

  /**
   * Migrations in dependency order.
   */
  private const MIGRATIONS = [
    'imagine_file_cover',
    'imagine_file_narration',
    'imagine_file_scene',
    'imagine_media_cover',
    'imagine_media_narration',
    'imagine_media_scene',
    'imagine_books',
    'imagine_book_translations',
    'imagine_chapters',
    'imagine_chapter_translations',
  ];

  /**
   * {@inheritdoc}
   */
  protected static $modules = [
    'system',
    'user',
    'field',
    'file',
    'image',
    'media',
    'node',
    'taxonomy',
    'text',
    'link',
    'menu_ui',
    'filter',
    'language',
    'content_translation',
    'migrate',
    'migrate_plus',
    'imagine_migrate',
  ];

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();
    $this->setSetting('imagine_source_dir', dirname(__DIR__, 2) . '/fixtures/content');

    $this->installEntitySchema('user');
    $this->installEntitySchema('file');
    $this->installEntitySchema('taxonomy_term');
    $this->installEntitySchema('node');
    $this->installEntitySchema('media');
    $this->installSchema('file', ['file_usage']);
    $this->installSchema('node', ['node_access']);
    $this->installConfig(['system', 'field', 'filter', 'language', 'media']);

    // Bundles, languages and translation settings. Saving the translation
    // settings makes content_translation add its own columns
    // (content_translation_source and friends) to the node and media tables.
    $this->importSyncConfig([
      'language.entity.fr',
      'language.entity.de',
      'node.type.book',
      'node.type.chapter',
      'media.type.audio',
      'media.type.image',
      'taxonomy.vocabulary.sdg',
      'language.content_settings.node.book',
      'language.content_settings.node.chapter',
      'language.content_settings.media.audio',
      'language.content_settings.media.image',
    ]);

    $fields = [
      'field.field.media.audio.field_media_audio_file',
      'field.field.media.image.field_media_image',
      'field.field.taxonomy_term.sdg.field_sdg_code',
    ];
    $sync = new FileStorage($this->syncDirectory());
    foreach (['book', 'chapter'] as $bundle) {
      $fields = array_merge($fields, $sync->listAll("field.field.node.$bundle."));
    }
    $storages = array_map(
      fn(string $name) => preg_replace('/^field\.field\.([^.]+)\.[^.]+\.(.+)$/', 'field.storage.$1.$2', $name),
      $fields,
    );
    $this->importSyncConfig(array_unique($storages));
    $this->importSyncConfig($fields);
  }

  /**
   * The real exported config folder (repo root /config/sync).
   */
  private function syncDirectory(): string {
    return $this->root . '/../config/sync';
  }

  /**
   * Creates config entities from their exported YAML.
   */
  private function importSyncConfig(array $names): void {
    $sync = new FileStorage($this->syncDirectory());
    $configManager = $this->container->get('config.manager');
    $entityTypeManager = $this->container->get('entity_type.manager');
    foreach ($names as $name) {
      $data = $sync->read($name);
      $this->assertIsArray($data, "Config $name exists in config/sync.");
      $entityTypeId = $configManager->getEntityTypeIdByName($name);
      $entityTypeManager->getStorage($entityTypeId)->createFromStorageRecord($data)->save();
    }
  }

  /**
   * Runs every migration once, in order.
   */
  private function migrateAll(bool $update = FALSE): void {
    $manager = $this->container->get('plugin.manager.migration');
    foreach (self::MIGRATIONS as $id) {
      $migration = $manager->createInstance($id);
      if ($update) {
        $migration->getIdMap()->prepareUpdate();
      }
      (new MigrateExecutable($migration, new MigrateMessage()))->import();
    }
  }

  /**
   * Returns how many entities of a type exist.
   */
  private function entityCount(string $entityTypeId): int {
    $query = $this->container->get('entity_type.manager')
      ->getStorage($entityTypeId)->getQuery()->accessCheck(FALSE);
    if ($entityTypeId === 'file') {
      // Media also creates its own generic thumbnail icons; only count ours.
      $query->condition('uri', 'public://imagine/', 'STARTS_WITH');
    }
    return (int) $query->count()->execute();
  }

  /**
   * Returns node, media and Imagine file counts.
   */
  private function counts(): array {
    return array_map($this->entityCount(...), ['node' => 'node', 'media' => 'media', 'file' => 'file']);
  }

  /**
   * Loads the only node of a bundle.
   */
  private function onlyNode(string $bundle, array $conditions = []): NodeInterface {
    $nodes = $this->container->get('entity_type.manager')->getStorage('node')
      ->loadByProperties(['type' => $bundle] + $conditions);
    $this->assertCount(1, $nodes);
    return reset($nodes);
  }

  /**
   * The French edition becomes a translation of the English book node.
   */
  public function testImportCreatesOneNodePerOriginalWithTranslations(): void {
    $this->migrateAll();

    $book = $this->onlyNode('book');
    $this->assertSame('en', $book->language()->getId());
    $this->assertSame("Alice's Adventures in Wonderland", $book->label());
    $this->assertSame('Lewis Carroll', $book->get('field_author')->value);
    $this->assertSame('https://www.gutenberg.org/ebooks/11', $book->get('field_source_url')->uri);
    $this->assertFalse($book->get('field_cover')->isEmpty());

    $this->assertTrue($book->hasTranslation('fr'));
    $fr = $book->getTranslation('fr');
    $this->assertSame("Aventures d'Alice au pays des merveilles", $fr->label());
    $this->assertSame('Henri Bué', $fr->get('field_translator')->value);
    $this->assertNotEquals($book->get('field_cover')->target_id, $fr->get('field_cover')->target_id);
  }

  /**
   * Chapters point at their book, narration and the shared English scenes.
   */
  public function testChaptersReferenceBookAndMedia(): void {
    $this->migrateAll();

    $book = $this->onlyNode('book');
    $chapter = $this->onlyNode('chapter');
    $this->assertSame('Down the Rabbit-Hole', $chapter->label());
    $this->assertSame((string) $book->id(), (string) $chapter->get('field_book')->target_id);
    $this->assertSame('1', (string) $chapter->get('field_index')->value);
    $this->assertSame('basic_html', $chapter->get('body')->format);
    $this->assertStringStartsWith('<p>Alice was beginning', $chapter->get('body')->value);
    $this->assertCount(2, $chapter->get('field_scenes'));

    $narration = $chapter->get('field_narration')->entity;
    $this->assertSame('audio', $narration->bundle());
    $this->assertSame('public://imagine/alice-in-wonderland/narration/1.mp3', $narration->get('field_media_audio_file')->entity->getFileUri());

    $fr = $chapter->getTranslation('fr');
    $this->assertSame('Au fond du terrier', $fr->label());
    $this->assertSame(
      array_column($chapter->get('field_scenes')->getValue(), 'target_id'),
      array_column($fr->get('field_scenes')->getValue(), 'target_id'),
    );
    $this->assertNotEquals($narration->id(), $fr->get('field_narration')->target_id);
  }

  /**
   * Running the migrations again, with or without --update, adds nothing.
   */
  public function testReimportIsIdempotent(): void {
    $this->migrateAll();
    $counts = $this->counts();
    $this->assertSame(['node' => 2, 'media' => 6, 'file' => 6], $counts);

    $this->migrateAll();
    $this->migrateAll(update: TRUE);
    $this->assertSame($counts, $this->counts());
    $this->assertCount(2, $this->onlyNode('chapter')->getTranslationLanguages());
  }

  /**
   * Book translations import cleanly, with no failed rows.
   *
   * Regression: a source option named "translations" made core's
   * NodeTranslationMigrateSubscriber (meant for Drupal 7 node migrations)
   * read a missing source "nid" after save and mark the row as failed.
   */
  public function testTranslationRowsAreNotFailed(): void {
    $this->migrateAll();
    $manager = $this->container->get('plugin.manager.migration');
    foreach (['imagine_book_translations', 'imagine_chapter_translations'] as $id) {
      $idMap = $manager->createInstance($id)->getIdMap();
      $this->assertSame(1, $idMap->importedCount(), $id);
      $this->assertSame(0, $idMap->errorCount(), $id);
    }
    $this->assertNull($this->container->get('state')->get('node_translation_redirect'));
  }

  /**
   * A translation whose original is missing is skipped with a message.
   *
   * French chapter 2 has text, but English chapter 2 does not, so there is
   * no English node to attach it to.
   */
  public function testOrphanTranslationSkipped(): void {
    $this->migrateAll();

    $migration = $this->container->get('plugin.manager.migration')->createInstance('imagine_chapter_translations');
    $idMap = $migration->getIdMap();
    $this->assertSame(1, $idMap->importedCount());
    $this->assertSame(0, $idMap->errorCount());
    $french1 = $idMap->getRowBySource(['book_id' => 'alice-au-pays-des-merveilles', 'index' => 1]);
    $this->assertEquals(MigrateIdMapInterface::STATUS_IMPORTED, $french1['source_row_status']);
    $french2 = $idMap->getRowBySource(['book_id' => 'alice-au-pays-des-merveilles', 'index' => 2]);
    $this->assertEquals(MigrateIdMapInterface::STATUS_IGNORED, $french2['source_row_status']);

    $messages = iterator_to_array($idMap->getMessages(['book_id' => 'alice-au-pays-des-merveilles', 'index' => 2]));
    $this->assertCount(1, $messages);
    $this->assertStringContainsString('original', $messages[0]->message);
  }

}
